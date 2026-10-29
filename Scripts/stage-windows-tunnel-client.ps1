param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('x64', 'ARM64')]
  [string]$Architecture,

  [Parameter(Mandatory = $true)]
  [string]$Destination
)

$ErrorActionPreference = 'Stop'

$release = 'v0.0.18'
if ($Architecture -eq 'ARM64') {
  $platform = @{
    Name = 'arm64'
    Machine = [UInt16]0xAA64
    ArchiveSHA256 = 'b73237513d50bf7acbeb960d80d9cbb6513879292f80ec1bd04b886fac1fe1c8'
    TunnelClientSHA256 = '71e8350e6dc14334b0d0ac2a637f98cdc0f0f1aac4dcd2f883354b2f9cbec70f'
    LicensesSHA256 = '4f0ad0501bf260d39369e6879661b5adf58b1d5ff01e4668605e0a32738d4445'
    SBOMSHA256 = '7aebe4c63a96bbdae601b65935fd60c760482ac9902b888c948d75b3c2cb3dd7'
  }
} else {
  $platform = @{
    Name = 'amd64'
    Machine = [UInt16]0x8664
    ArchiveSHA256 = '8d0da1ce79532d44ccc5ed5d8bd36cdfffba37dfd287c602d69635c8bb5db2b2'
    TunnelClientSHA256 = '9d0a22b7eb64fe7c5e34dfc97273ffcab6a07557855cf9e7f8869068402caf6b'
    LicensesSHA256 = '2b1def83c55dea817579ea1a7206119356c6a97a190c31181fe7817ae60c29ec'
    SBOMSHA256 = '6fdf06f5663980bb01e63417a6fa9dc0f42a20aa7f5498b7e444e6977bcc43d7'
  }
}

function Assert-SHA256([string]$Path, [string]$Expected) {
  $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -cne $Expected) {
    throw "SHA-256 mismatch for $(Split-Path $Path -Leaf): expected $Expected, got $actual"
  }
}

function Assert-PEMachine([string]$Path, [UInt16]$Expected) {
  $stream = [IO.File]::Open($Path, 'Open', 'Read', 'Read')
  $reader = [IO.BinaryReader]::new($stream)
  try {
    if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne [UInt16]0x5A4D) {
      throw "Invalid DOS signature: $Path"
    }
    $stream.Seek(0x3C, [IO.SeekOrigin]::Begin) | Out-Null
    $peOffset = $reader.ReadUInt32()
    if ($peOffset -gt 1MB -or $peOffset -gt ($stream.Length - 24)) {
      throw "Invalid PE header offset: $Path"
    }
    $stream.Seek([Int64]$peOffset, [IO.SeekOrigin]::Begin) | Out-Null
    if ($reader.ReadUInt32() -ne [UInt32]0x00004550) {
      throw "Invalid PE signature: $Path"
    }
    $machine = $reader.ReadUInt16()
    $stream.Seek([Int64]$peOffset + 22, [IO.SeekOrigin]::Begin) | Out-Null
    $characteristics = $reader.ReadUInt16()
    if ($machine -ne $Expected -or ($characteristics -band [UInt16]0x0002) -eq 0) {
      throw "Unexpected PE architecture for $Path"
    }
  } finally {
    $reader.Dispose()
    $stream.Dispose()
  }
}

$attributionHashes = [ordered]@{
  LICENSE = 'f4c1d7ba32ef5bcf5cf03e2eefec5825ebafedf50fa330a36700a49c605c1ef4'
  NOTICE = '1364c020d86ecf948b78b7c655175032068203d13aece70fb0bfe112d7802dc2'
  'THIRD-PARTY-LICENSES.txt' = $platform.LicensesSHA256
  'SBOM.spdx.json' = $platform.SBOMSHA256
}

if (Test-Path -LiteralPath $Destination) {
  $executable = Join-Path $Destination 'tunnel-client.exe'
  Assert-SHA256 $executable $platform.TunnelClientSHA256
  Assert-PEMachine $executable $platform.Machine
  $digest = (Get-Content -LiteralPath (Join-Path $Destination 'tunnel-client.sha256') -Raw).Trim()
  if ($digest -cne $platform.TunnelClientSHA256) {
    throw 'Cached tunnel client digest does not match the pinned release.'
  }
  foreach ($name in $attributionHashes.Keys) {
    Assert-SHA256 (Join-Path $Destination "TunnelClient/$name") $attributionHashes[$name]
  }
  Write-Host "Using verified $release $Architecture tunnel-client from $Destination"
  return
}

$archiveName = "tunnel-client-$release-windows-$($platform.Name).zip"
$url = "https://github.com/openai/tunnel-client/releases/download/$release/$archiveName"
$work = Join-Path $env:TEMP "CodexBridge-TunnelClient-$Architecture-$([Guid]::NewGuid().ToString('N'))"
$archive = Join-Path $work $archiveName
$extract = Join-Path $work 'extract'
New-Item -ItemType Directory -Path $extract -Force | Out-Null

try {
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archive
  Assert-SHA256 $archive $platform.ArchiveSHA256

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($archive)
  try {
    $archiveBase = [IO.Path]::GetFileNameWithoutExtension($archiveName)
    $expectedEntries = @(
      'tunnel-client.exe', 'cloudflared.exe', 'cloudflared-manifest.json', 'LICENSE', 'NOTICE',
      "$archiveBase-licenses.txt", "$archiveBase.spdx.json"
    )
    if ($zip.Entries.Count -ne $expectedEntries.Count) {
      throw "Unexpected archive layout: $archiveName"
    }
    foreach ($name in $expectedEntries) {
      $entries = @($zip.Entries | Where-Object { $_.FullName -ceq $name })
      if ($entries.Count -ne 1 -or (($entries[0].ExternalAttributes -shr 16) -band 0xF000) -ne 0x8000) {
        throw "Missing or irregular archive member: $name"
      }
    }
    [IO.Compression.ZipFileExtensions]::ExtractToFile(
      $zip.GetEntry('tunnel-client.exe'), (Join-Path $extract 'tunnel-client.exe'), $true)
    $attribution = Join-Path $extract 'TunnelClient'
    New-Item -ItemType Directory -Path $attribution | Out-Null
    $members = [ordered]@{
      LICENSE = 'LICENSE'
      NOTICE = 'NOTICE'
      'THIRD-PARTY-LICENSES.txt' = "$archiveBase-licenses.txt"
      'SBOM.spdx.json' = "$archiveBase.spdx.json"
    }
    foreach ($name in $members.Keys) {
      $path = Join-Path $attribution $name
      [IO.Compression.ZipFileExtensions]::ExtractToFile($zip.GetEntry($members[$name]), $path, $true)
      Assert-SHA256 $path $attributionHashes[$name]
    }
  } finally {
    $zip.Dispose()
  }
  $executable = Join-Path $extract 'tunnel-client.exe'
  Assert-SHA256 $executable $platform.TunnelClientSHA256
  Assert-PEMachine $executable $platform.Machine

  $destinationFull = [IO.Path]::GetFullPath($Destination)
  New-Item -ItemType Directory -Path $destinationFull -Force | Out-Null
  Copy-Item -LiteralPath $executable -Destination (Join-Path $destinationFull 'tunnel-client.exe') -Force
  Copy-Item -LiteralPath $attribution -Destination $destinationFull -Recurse -Force
  [IO.File]::WriteAllText(
    (Join-Path $destinationFull 'tunnel-client.sha256'),
    ($platform.TunnelClientSHA256 + [Environment]::NewLine))
  $manifest = [ordered]@{
    schema = 'codex-bridge-tunnel-client/v1'
    release = $release
    architecture = $Architecture
    peMachine = ('0x{0:X4}' -f $platform.Machine)
    archiveSHA256 = $platform.ArchiveSHA256
    tunnelClientSHA256 = $platform.TunnelClientSHA256
    sourceURL = $url
    upstreamCommit = '274a5588414819f063d27100a4fb1096aae3830f'
    attributionSHA256 = $attributionHashes
  }
  $utf8NoBom = [Text.UTF8Encoding]::new($false)
  [IO.File]::WriteAllText(
    (Join-Path $destinationFull 'tunnel-client.manifest.json'),
    (($manifest | ConvertTo-Json -Depth 3) + [Environment]::NewLine),
    $utf8NoBom)
  Write-Host "Staged $release $Architecture tunnel-client into $destinationFull"
} finally {
  if (Test-Path -LiteralPath $work) {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  }
}

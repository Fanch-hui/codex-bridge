param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('x64', 'ARM64')]
  [string]$Architecture,

  [Parameter(Mandatory = $true)]
  [string]$Destination
)

$ErrorActionPreference = 'Stop'

$release = 'v0.0.17'
if ($Architecture -eq 'ARM64') {
  $platform = @{
    Name = 'arm64'
    Machine = [UInt16]0xAA64
    ArchiveSHA256 = '925c8298e46e088413bb02c81d36775f2e818970231bc2ecc215fcb0f0382bf7'
    TunnelClientSHA256 = '2986f8ea93ead7462d0babfecd858bf50dd04dff750fbab938e182ec6544f590'
    LicensesSHA256 = '56c9285870b684aedb9b837cd9278682595192f89ea4a0b39e3147679a755eb4'
    SBOMSHA256 = '65ea6b5f855a27fba9c835c149c4e99f76316e49a27600bf1ce321e73e1ad47a'
  }
} else {
  $platform = @{
    Name = 'amd64'
    Machine = [UInt16]0x8664
    ArchiveSHA256 = 'b89074637596262067061308cf174959561a1a8bcffe2db956650dad7303052b'
    TunnelClientSHA256 = '61a770c759c386845f830a106f7e6d0d3f854b932259744a88b4013c282e64ec'
    LicensesSHA256 = '7fa05f02e1187d6bb5df44133cc02669f42c8d11a0c3ea818780d86c5ed66235'
    SBOMSHA256 = '1449368915f606868a2ec6970d7ba5bf86d2afd11b03a3d9e89f64109279a62e'
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
    upstreamCommit = 'a248b7f725fc989c1eb26680cf4351ee33421f61'
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

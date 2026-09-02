param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('x64', 'ARM64')]
  [string]$Architecture,

  [Parameter(Mandatory = $true)]
  [string]$Destination
)

$ErrorActionPreference = 'Stop'

$release = 'v0.0.10'
if ($Architecture -eq 'ARM64') {
  $platform = @{
    Name = 'arm64'
    Machine = [UInt16]0xAA64
    ArchiveSHA256 = '08954ccda078abfeac9382f9b19d178ce0656cfe1e84f5941f0f8a5c4e91ea78'
    TunnelClientSHA256 = '6166dbb93064c3979ab388b3ba72fe2a24c475b77a09a391e007d6070d17785d'
  }
} else {
  $platform = @{
    Name = 'amd64'
    Machine = [UInt16]0x8664
    ArchiveSHA256 = '5e64a056f1d96786da0a6f8db1da5f5f4a03fd19a90d951a25cf2ca8d9093d00'
    TunnelClientSHA256 = 'd893d8127eee35070d265c1be29bfe008f8d9fcb476e7febf56c8fdc6c0615c8'
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

if (Test-Path -LiteralPath $Destination) {
  throw "Tunnel client destination already exists: $Destination"
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
    if ($zip.Entries.Count -ne 1 -or $zip.Entries[0].FullName -ne 'tunnel-client.exe') {
      throw "Unexpected archive layout: $archiveName"
    }
    [IO.Compression.ZipFileExtensions]::ExtractToFile(
      $zip.Entries[0],
      (Join-Path $extract 'tunnel-client.exe'),
      $true)
  } finally {
    $zip.Dispose()
  }
  $executable = Join-Path $extract 'tunnel-client.exe'
  Assert-SHA256 $executable $platform.TunnelClientSHA256
  Assert-PEMachine $executable $platform.Machine

  $destinationFull = [IO.Path]::GetFullPath($Destination)
  New-Item -ItemType Directory -Path $destinationFull -Force | Out-Null
  Copy-Item -LiteralPath $executable -Destination (Join-Path $destinationFull 'tunnel-client.exe') -Force
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
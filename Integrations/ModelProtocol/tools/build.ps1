param(
  [Parameter(Mandatory = $true)][ValidateSet('darwin', 'windows', 'linux')][string]$TargetOS,
  [Parameter(Mandatory = $true)][ValidateSet('amd64', 'arm64')][string]$TargetArch,
  [Parameter(Mandatory = $true)][string]$Output
)

$ErrorActionPreference = 'Stop'
$go = if ($env:GO) { $env:GO } else { 'go' }
$outputPath = [System.IO.Path]::GetFullPath($Output)
$modulePath = Split-Path -Parent $PSScriptRoot
$previous = @{}
foreach ($name in @('CGO_ENABLED', 'GOOS', 'GOARCH', 'GOTOOLCHAIN')) {
  $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

try {
  $env:CGO_ENABLED = '0'
  $env:GOOS = $TargetOS
  $env:GOARCH = $TargetArch
  $env:GOTOOLCHAIN = 'local'
  Push-Location $modulePath
  try {
    & $go build -buildvcs=false -trimpath -mod=readonly -o $outputPath ./cmd/model-protocol
    if ($LASTEXITCODE -ne 0) { throw "Go build failed with exit code $LASTEXITCODE" }
  } finally {
    Pop-Location
  }
} finally {
  foreach ($name in $previous.Keys) {
    [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
  }
}

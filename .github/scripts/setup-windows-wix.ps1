Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Join-Path $env:RUNNER_TEMP "wix-3.14.1"
$archive = "$root.zip"
$uri = "https://github.com/wixtoolset/wix3/releases/download/wix3141rtm/wix314-binaries.zip"
$expectedHash = "6ac824e1642d6f7277d0ed7ea09411a508f6116ba6fae0aa5f2c7daa2ff43d31"
Invoke-WebRequest -Uri $uri -OutFile $archive
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) {
  throw "WiX archive SHA-256 did not match the pinned value."
}
Expand-Archive -LiteralPath $archive -DestinationPath $root -Force
if (-not (Test-Path -LiteralPath (Join-Path $root "dark.exe") -PathType Leaf)) {
  throw "WiX dark.exe was not extracted."
}
Add-Content $env:GITHUB_PATH $root

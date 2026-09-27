[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$downloadDirectory = Join-Path $env:RUNNER_TEMP "swift-downloads"
$installer = Join-Path $downloadDirectory "swift-$Version-windows.exe"
New-Item -ItemType Directory -Path $downloadDirectory -Force | Out-Null
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
  $uri = "https://download.swift.org/swift-$Version-release/windows10/swift-$Version-RELEASE/swift-$Version-RELEASE-windows10.exe"
  Invoke-WebRequest -Uri $uri -OutFile $installer
}
$process = Start-Process -Wait -PassThru -FilePath $installer `
  -ArgumentList "/quiet", "/norestart", "InstallPerMachine=1"
if ($process.ExitCode -notin @(0, 3010)) {
  throw "Swift installer failed: $($process.ExitCode)"
}
$roots = @(
  "$env:ProgramFiles\Swift",
  "$env:LOCALAPPDATA\Programs\Swift",
  "C:\Library\Developer\Toolchains"
)
$candidates = Get-ChildItem $roots -Recurse -Filter swift.exe `
  -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
# Prefer the standard toolchain over the +Asserts variant.
$swiftExe = ($candidates | Where-Object { $_ -notmatch '\+Asserts' } |
  Select-Object -First 1)
if (-not $swiftExe) { $swiftExe = $candidates | Select-Object -First 1 }
if (-not $swiftExe) { throw "swift.exe not found after install" }
Write-Host "found swift at $swiftExe"
$swiftBin = Split-Path $swiftExe
Add-Content $env:GITHUB_PATH $swiftBin
$toolchainVersionDirectory = (Get-Item $swiftBin).Parent.Parent
if (-not $toolchainVersionDirectory -or
    -not $toolchainVersionDirectory.Parent.Name.Equals("Toolchains", [StringComparison]::OrdinalIgnoreCase)) {
  throw "Swift toolchain version directory was not found."
}
$swiftRoot = $toolchainVersionDirectory.Parent.Parent.FullName
$sdkVersion = $toolchainVersionDirectory.Name -replace "\+.*$", ""
if ($sdkVersion -ne $Version) { throw "Expected Swift $Version, found $sdkVersion" }
# The host runtime is separate from the toolchain and must be on PATH.
$runtimeBin = Join-Path $swiftRoot "Runtimes\$sdkVersion\usr\bin"
if (-not (Test-Path (Join-Path $runtimeBin "swiftCore.dll"))) {
  throw "Version-matching swiftCore.dll was not found after install."
}
Write-Host "found runtime at $runtimeBin"
Add-Content $env:GITHUB_PATH $runtimeBin
# The installer ships a version-matched Windows SDK separately from
# the toolchain. Installer environment changes do not reach an
# already-running job, so forward the exact SDK explicitly.
$platformDir = Join-Path $swiftRoot "Platforms\$sdkVersion\Windows.platform"
$sdkRoot = Join-Path $platformDir "Developer\SDKs\Windows.sdk"
if (-not (Test-Path -LiteralPath $sdkRoot -PathType Container)) {
  throw "Version-matching Swift Windows SDK was not found."
}
Write-Host "SDKROOT=$sdkRoot"
Add-Content $env:GITHUB_ENV "SDKROOT=$sdkRoot"

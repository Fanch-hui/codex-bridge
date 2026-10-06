[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$InstallerPath,
  [Parameter(Mandatory = $true)]
  [ValidateSet("x64", "arm64")]
  [string]$Architecture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($env:OS -ne "Windows_NT" -or $env:RUNNER_ENVIRONMENT -ne "github-hosted") {
  throw "Installer verification requires a GitHub-hosted Windows runner."
}
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
. (Join-Path $repoRoot "Scripts\windows-portable-support.ps1")
$installer = Get-FullPath $InstallerPath
Assert-RegularFile $installer | Out-Null
$configuration = [IO.File]::ReadAllText((Join-Path $repoRoot "Config\Base.xcconfig"))
$version = [regex]::Match($configuration, '(?m)^MARKETING_VERSION\s*=\s*(\S+)').Groups[1].Value
$verificationRoot = Join-Path $env:RUNNER_TEMP ("Codex Bridge installer " + [Guid]::NewGuid().ToString("N"))
$installRoot = Join-Path $verificationRoot "application"
$appPath = Join-Path $installRoot "codex-bridge-windows-app.exe"
$servicePath = Join-Path $installRoot "codex-bridge-service.exe"
$uninstallerPath = Join-Path $installRoot "unins000.exe"
$service = $null
$environment = @{}
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{6F51B5A4-4C25-4E72-A8E5-93447D72D031}_is1"
if (Test-Path -LiteralPath $uninstallKey) {
  throw "The runner already has a registered Codex Bridge installation."
}

function Invoke-Control([string]$Executable, [string[]]$Arguments, [int]$Seconds = 45) {
  $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -PassThru
  $exitCode = Wait-DirectProcessExit $process $Seconds (Split-Path -Leaf $Executable)
  if ($exitCode -ne 0) { throw "$(Split-Path -Leaf $Executable) returned $exitCode." }
}

function Invoke-Installer([string]$Executable, [string]$Stage, [switch]$Uninstall) {
  $arguments = @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART",
    "/LOG=`"$(Join-Path $verificationRoot "$Stage.log")`"")
  if (-not $Uninstall) { $arguments += @("/SP-", "/DIR=`"$installRoot`"") }
  Invoke-Control $Executable $arguments 120
}

function Assert-InstalledPayload {
  foreach ($name in @("codex-bridge-windows-app.exe", "codex-bridge-service.exe",
      "swiftCore.dll", "sqlite3.dll", "WebView2Loader.dll", "tunnel-client.exe",
      "tunnel-client.sha256", "BUILD-INFO.json", "SHA256SUMS.txt", "CodexBridgeControl.v1",
      "AppIcon.ico", "unins000.exe")) {
    Assert-RegularFile (Join-Path $installRoot $name) | Out-Null
  }
  $info = Get-Content -LiteralPath (Join-Path $installRoot "BUILD-INFO.json") -Raw | ConvertFrom-Json
  if ($info.appVersion -ne $version -or $info.architecture -ne $Architecture) {
    throw "Installed version or architecture does not match the release."
  }
  $expectedMachine = if ($Architecture -eq "x64") { [UInt16]0x8664 } else { [UInt16]0xAA64 }
  foreach ($executable in @($appPath, $servicePath, (Join-Path $installRoot "tunnel-client.exe"))) {
    if ((Get-PEMachine $executable) -ne $expectedMachine) { throw "Installed executable architecture mismatch." }
  }
  foreach ($line in Get-Content -LiteralPath (Join-Path $installRoot "SHA256SUMS.txt")) {
    if ($line -notmatch '^([0-9a-fA-F]{64})  (.+)$') { throw "Invalid installed payload manifest." }
    $digest = $Matches[1].ToLowerInvariant()
    $candidate = Get-FullPath (Join-Path $installRoot ($Matches[2] -replace "/", "\"))
    if (-not (Test-SameOrChildPath $installRoot $candidate)) { throw "Payload manifest path escapes installation." }
    Assert-RegularFile $candidate | Out-Null
    if ((Get-Sha256 $candidate) -ne $digest) { throw "Installed payload checksum mismatch." }
  }
  $helperDigest = (Get-Content -LiteralPath (Join-Path $installRoot "tunnel-client.sha256") -Raw).Trim()
  if ((Get-Sha256 (Join-Path $installRoot "tunnel-client.exe")) -cne $helperDigest) {
    throw "Installed Tunnel helper digest mismatch."
  }
  foreach ($module in @("BridgeDesktopUI", "BridgePiRPC", "BridgeQoderSDK", "BridgeDeepSeekHarnessACP",
      "BridgeDeepSeekHarnessDesktop")) {
    $resources = @(Get-ChildItem -LiteralPath $installRoot -Directory | Where-Object {
        $_.Name -in @("BridgeCore_$module.bundle", "BridgeCore_$module.resources")
      })
    if ($resources.Count -ne 1) { throw "Installed resources are missing for $module." }
    Assert-Directory $resources[0].FullName | Out-Null
  }
}

function Start-InstalledService {
  Invoke-Control $appPath @("--ensure-service")
  $matches = @(Get-Process -Name "codex-bridge-service" -ErrorAction SilentlyContinue | Where-Object {
      try { (Get-ComparablePath $_.Path) -eq (Get-ComparablePath $servicePath) } catch { $false }
    })
  if ($matches.Count -ne 1) { throw "Installed application did not start exactly one service." }
  $script:service = $matches[0]
  Write-Host "Installed application reached service IPC readiness."
}

function Assert-ServiceExited {
  if ($null -eq $script:service) { return }
  if (-not $script:service.WaitForExit(30000)) { throw "Installed service did not exit." }
  $script:service.Dispose()
  $script:service = $null
}

New-Item -ItemType Directory -Path $verificationRoot | Out-Null
try {
  foreach ($name in @("LOCALAPPDATA", "APPDATA", "USERPROFILE")) {
    $environment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    $directory = Join-Path $verificationRoot $name
    New-Item -ItemType Directory -Path $directory | Out-Null
    [Environment]::SetEnvironmentVariable($name, $directory, "Process")
  }
  Invoke-Installer $installer "install"
  Assert-InstalledPayload
  Start-InstalledService
  Invoke-Control $servicePath @("--shutdown")
  Assert-ServiceExited
  Write-Host "Release $version ($Architecture): install, payload integrity, IPC startup and shutdown passed."

  Start-InstalledService
  Invoke-Installer $installer "reinstall"
  Assert-ServiceExited
  Assert-InstalledPayload
  Write-Host "Same-version overwrite installation passed."

  Start-InstalledService
  Invoke-Installer $uninstallerPath "uninstall" -Uninstall
  Assert-ServiceExited
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  while ((Test-Path -LiteralPath $installRoot) -and [DateTime]::UtcNow -lt $deadline) {
    $remaining = @(Get-ChildItem -LiteralPath $installRoot -Force)
    if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $installRoot -Force; break }
    Start-Sleep -Milliseconds 200
  }
  if (Test-Path -LiteralPath $installRoot) { throw "Installation files remain after uninstall." }
  if (Test-Path -LiteralPath $uninstallKey) { throw "Uninstall registration remains." }
  Write-Host "Installer uninstall and installation-directory removal passed."
} finally {
  try {
    if ($null -ne $service) {
      try { Invoke-Control $servicePath @("--shutdown"); Assert-ServiceExited } catch {
        $service.Refresh()
        if (-not $service.HasExited -and (Get-ComparablePath $service.Path) -eq (Get-ComparablePath $servicePath)) {
          Stop-Process -Id $service.Id -Force
          $service.WaitForExit(10000) | Out-Null
        }
      }
    }
    if (Test-Path -LiteralPath $uninstallerPath) {
      try { Invoke-Installer $uninstallerPath "cleanup" -Uninstall } catch { Write-Warning $_ }
    }
  } finally {
    foreach ($name in $environment.Keys) {
      [Environment]::SetEnvironmentVariable($name, $environment[$name], "Process")
    }
    Remove-ExactPath $verificationRoot
  }
}

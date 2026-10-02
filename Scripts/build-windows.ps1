# Builds the Windows targets (service daemon and desktop shell) for x64 or ARM64.
# Run on a Windows machine with the Swift 6.3.3 toolchain:
#   powershell -File Scripts\build-windows.ps1 [-Installer] [-OutDir path]
param(
  [ValidateSet("x64", "arm64")]
  [string]$Architecture = "",
  [switch]$Installer,
  [string]$OutDir = ".build\windows-dist",
  [string]$VcpkgRoot = "",
  [string]$VCRedistRoot = "",
  [string]$TunnelClientDir = "",
  [string]$ISCCPath = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$packagePath = Join-Path $repoRoot "Packages\BridgeCore"
$resolvedOutDir = if ([IO.Path]::IsPathRooted($OutDir)) {
  [IO.Path]::GetFullPath($OutDir)
} else {
  [IO.Path]::GetFullPath((Join-Path $repoRoot $OutDir))
}
$resolvedVcpkgRoot = if ([string]::IsNullOrWhiteSpace($VcpkgRoot)) {
  ""
} elseif ([IO.Path]::IsPathRooted($VcpkgRoot)) {
  [IO.Path]::GetFullPath($VcpkgRoot)
} else {
  [IO.Path]::GetFullPath((Join-Path $repoRoot $VcpkgRoot))
}
$resolvedVCRedistRoot = if ([string]::IsNullOrWhiteSpace($VCRedistRoot)) {
  ""
} elseif ([IO.Path]::IsPathRooted($VCRedistRoot)) {
  [IO.Path]::GetFullPath($VCRedistRoot)
} else {
  [IO.Path]::GetFullPath((Join-Path $repoRoot $VCRedistRoot))
}

try {
  $hostArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
} catch {
  $hostArchitecture = $env:PROCESSOR_ARCHITECTURE
}
if (-not $Architecture) {
  switch ($hostArchitecture.ToUpperInvariant()) {
    "X64" { $Architecture = "x64" }
    "ARM64" { $Architecture = "arm64" }
    default { throw "Unsupported Windows host architecture: $hostArchitecture" }
  }
}
$architecture = $Architecture.ToLowerInvariant()
$vcpkgTriplet = "$architecture-windows"
$targetTriple = if ($architecture -eq "arm64") {
  "aarch64-unknown-windows-msvc"
} else {
  "x86_64-unknown-windows-msvc"
}
$vcpkgRootValue = if ($resolvedVcpkgRoot) {
  $resolvedVcpkgRoot
} elseif (Test-Path Env:VCPKG_INSTALLATION_ROOT) {
  $env:VCPKG_INSTALLATION_ROOT
} else {
  ""
}
$originalPath = $env:PATH
$originalInclude = $env:INCLUDE
$originalLib = $env:LIB
$originalWindowsResource = $env:CODEX_BRIDGE_WINDOWS_RESOURCE

$resourceOutput = Join-Path $resolvedOutDir "CodexBridgeWindowsApp.res"
& (Join-Path $repoRoot "Scripts\compile-windows-resources.ps1") -OutputPath $resourceOutput
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$env:CODEX_BRIDGE_WINDOWS_RESOURCE = [IO.Path]::GetFullPath($resourceOutput)

. (Join-Path $PSScriptRoot "windows-build-environment.ps1")
$buildEnvironment = Get-WindowsBuildEnvironment -Architecture $architecture

$cleanSdkCandidates = @(
  "C:\Program Files\Swift\Platforms\6.3.3\Windows.platform\Developer\SDKs\Windows.sdk",
  "C:\Swift\Platforms\6.3.3\Windows.platform\Developer\SDKs\Windows.sdk"
)
foreach ($candidate in $cleanSdkCandidates) {
  if (Test-Path -LiteralPath $candidate -PathType Container) {
    if ([string]::IsNullOrWhiteSpace($env:SDKROOT) -or $env:SDKROOT -match '[^\u0000-\u007F]') {
      $env:SDKROOT = $candidate
    }
    break
  }
}

if (-not $vcpkgRootValue) {
  throw "VcpkgRoot or VCPKG_INSTALLATION_ROOT is required."
}
$vcpkgInstalledRoot = Join-Path $vcpkgRootValue "installed\$vcpkgTriplet"
$vcpkgIncludeDirectory = Join-Path $vcpkgInstalledRoot "include"
$vcpkgLibraryDirectory = Join-Path $vcpkgInstalledRoot "lib"
$sqliteHeader = Join-Path $vcpkgIncludeDirectory "sqlite3.h"
$sqliteLibrary = Join-Path $vcpkgLibraryDirectory "sqlite3.lib"
foreach ($requiredPath in @($sqliteHeader, $sqliteLibrary)) {
  if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
    throw "Vcpkg SQLite development file is unavailable: $requiredPath"
  }
}
$env:INCLUDE = (@($vcpkgIncludeDirectory) + $buildEnvironment.IncludePaths) -join ";"
$env:LIB = (@($vcpkgLibraryDirectory) + $buildEnvironment.LibraryPaths) -join ";"
. (Join-Path $PSScriptRoot "windows-portable-support.ps1")
$sqliteRuntime = Join-Path $vcpkgInstalledRoot "bin\sqlite3.dll"
$expectedMachine = if ($architecture -eq "arm64") { [UInt16]0xAA64 } else { [UInt16]0x8664 }
if ((Get-PEMachine $sqliteRuntime) -ne $expectedMachine) {
  throw "SQLite runtime does not match the $architecture target: $sqliteRuntime"
}


Push-Location $packagePath
try {
  . (Join-Path $PSScriptRoot "windows-swift-arguments.ps1")
  $swiftArguments = @(Get-WindowsSwiftArguments `
    -VcpkgInstalledRoot $vcpkgInstalledRoot -TargetTriple $targetTriple `
    -LibraryPaths $buildEnvironment.LibraryPaths)
  $buildArguments = @($swiftArguments) + @("-c", "release")
  swift build @buildArguments --product codex-bridge-service
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  swift build @buildArguments --product codex-bridge-windows-app
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

  $binPathOutput = & swift build @buildArguments --show-bin-path
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  $binPath = ($binPathOutput | Select-Object -Last 1).ToString().Trim()
  if ([string]::IsNullOrWhiteSpace($binPath)) {
    throw "Swift build output directory was empty."
  }


  $portableDir = Join-Path $resolvedOutDir $architecture
  $stageScript = Join-Path $repoRoot "Scripts\stage-windows-portable.ps1"
  $stageArguments = @{
    BinPath = $binPath
    OutDir = $portableDir
    Architecture = $architecture
    VcpkgTriplet = $vcpkgTriplet
  }
  if ($targetTriple) {
    $stageArguments["TargetTriple"] = $targetTriple
  }
  if ($resolvedVcpkgRoot) {
    $stageArguments["VcpkgRoot"] = $resolvedVcpkgRoot
  }
  if ($resolvedVCRedistRoot) {
    $stageArguments["VCRedistRoot"] = $resolvedVCRedistRoot
  }
  if (-not [string]::IsNullOrWhiteSpace($TunnelClientDir)) {
    $resolvedTunnelClientDir = if ([IO.Path]::IsPathRooted($TunnelClientDir)) {
      [IO.Path]::GetFullPath($TunnelClientDir)
    } else {
      [IO.Path]::GetFullPath((Join-Path $repoRoot $TunnelClientDir))
    }
    $stageArguments["TunnelClientDir"] = $resolvedTunnelClientDir
  } else {
    $resolvedTunnelClientDir = Join-Path $resolvedOutDir "tunnel-client"
    & (Join-Path $repoRoot "Scripts\stage-windows-tunnel-client.ps1") `
      -Architecture $architecture -Destination $resolvedTunnelClientDir
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $stageArguments["TunnelClientDir"] = $resolvedTunnelClientDir
  }
  & $stageScript @stageArguments
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

  if ($Installer) {
    $installerOutDir = Join-Path $repoRoot ".build\windows-installer\$architecture"
    $installerArguments = @{
      Architecture = $architecture
      PayloadDir = $portableDir
      OutputDir = $installerOutDir
    }
    if ($ISCCPath) {
      $installerArguments["ISCCPath"] = $ISCCPath
    }
    & (Join-Path $repoRoot "Scripts\build-windows-installer.ps1") @installerArguments
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }
} finally {
  Pop-Location
  $env:PATH = $originalPath
  $env:INCLUDE = $originalInclude
  $env:LIB = $originalLib
  if ($null -eq $originalWindowsResource) {
    Remove-Item Env:CODEX_BRIDGE_WINDOWS_RESOURCE -ErrorAction SilentlyContinue
  } else {
    $env:CODEX_BRIDGE_WINDOWS_RESOURCE = $originalWindowsResource
  }
}

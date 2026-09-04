# Builds the Windows targets (service daemon and desktop shell) for the host
# architecture. Run on a Windows machine with the Swift 6.3.3 toolchain:
#   powershell -File Scripts\build-windows.ps1 [-Test] [-Installer] [-OutDir path]
param(
  [switch]$Test,
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
switch ($hostArchitecture.ToUpperInvariant()) {
  "X64" { $architecture = "x64" }
  "ARM64" { $architecture = "arm64" }
  default { throw "Unsupported Windows host architecture: $hostArchitecture" }
}
$vcpkgTriplet = "$architecture-windows"
$targetTriple = if ($architecture -eq "arm64") { "aarch64-unknown-windows-msvc" } else { "" }
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

if ([string]::IsNullOrWhiteSpace($originalInclude) -or [string]::IsNullOrWhiteSpace($originalLib)) {
  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  if (Test-Path $vswhere) {
    $vsRoot = & $vswhere -latest -property installationPath | Select-Object -First 1
    if ($vsRoot) {
      $msvcRoot = Get-ChildItem "$vsRoot\VC\Tools\MSVC" -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
      $kitsInc = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\Include" -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
      $kitsLib = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\Lib" -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName

      if ($msvcRoot -and $kitsInc -and [string]::IsNullOrWhiteSpace($originalInclude)) {
        $originalInclude = @(
          "$msvcRoot\include",
          "$kitsInc\ucrt",
          "$kitsInc\um",
          "$kitsInc\shared",
          "$kitsInc\winrt"
        ) -join ";"
      }
      if ($msvcRoot -and $kitsLib -and [string]::IsNullOrWhiteSpace($originalLib)) {
        $archDir = if ($architecture -eq "arm64") { "arm64" } else { "x64" }
        $originalLib = @(
          "$msvcRoot\lib\$archDir",
          "$kitsLib\um\$archDir",
          "$kitsLib\ucrt\$archDir"
        ) -join ";"
      }
    }
  }
}

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
$env:INCLUDE = (@($vcpkgIncludeDirectory, $originalInclude) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ";"
$env:LIB = (@($vcpkgLibraryDirectory, $originalLib) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ";"

if ($Test) {
  $sqliteRuntimeDirectory = Join-Path $vcpkgRootValue "installed\$vcpkgTriplet\bin"
  if (-not (Test-Path (Join-Path $sqliteRuntimeDirectory "sqlite3.dll"))) {
    throw "SQLite runtime is unavailable: $sqliteRuntimeDirectory\sqlite3.dll"
  }
  $env:PATH = "$sqliteRuntimeDirectory;$originalPath"
}

Push-Location $packagePath
try {
  $swiftArguments = @(
    "-Xswiftc", "-DSQLITE_DISABLE_SNAPSHOT",
    "-Xswiftc", "-I$vcpkgIncludeDirectory",
    "-Xswiftc", "-Xcc", "-Xswiftc", "-I$vcpkgIncludeDirectory",
    "-Xcc", "-DNOMINMAX",
    "-Xcc", "-I$vcpkgIncludeDirectory",
    "-Xlinker", "-libpath:$vcpkgLibraryDirectory",
    "--build-system", "swiftbuild"
  )
  if ($targetTriple) {
    $swiftArguments += @("--triple", $targetTriple)
  }
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

  if ($Test) {
    foreach ($testFilter in @(
        "BridgeDomainTests",
        "BridgeAgentCoreTests",
        "BridgeSecurityTests",
        "BridgeCodexRPCTests",
        "BridgeDesktopUITests",
        "BridgeServiceAppCoreTests",
        "BridgeServiceHostWindowsTests",
        "BridgeTunnelWindowsTests",
        "BridgeCodexServiceWindowsTests",
        "BridgeServiceApplicationWindowsTests",
        "BridgeServiceCoreWindowsTests",
        "BridgeDirectCommandWindowsTests",
        "BridgeWindowsShellTests")) {
      $testArgs = @("test") + $swiftArguments + @("--filter", $testFilter)
      if ($testFilter -eq "BridgeSecurityTests") {
        $testArgs += @("--skip", "WindowsCredentialStoreTests")
      }
      swift @testArgs
      if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
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
}

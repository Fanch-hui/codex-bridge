param([Parameter(Mandatory)][ValidateSet("x64", "arm64")][string]$Architecture)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "../../Scripts/windows-swift-arguments.ps1")
$vcpkg = Join-Path $env:VCPKG_INSTALLATION_ROOT "installed/$Architecture-windows"
$arguments = @(Get-WindowsSwiftArguments -VcpkgInstalledRoot $vcpkg -TargetTriple $env:TARGET_TRIPLE `
  -LibraryPaths ($env:TARGET_LIBRARY_PATHS -split ";"))
$msvc = @($env:INCLUDE -split ";" | Where-Object { Test-Path -LiteralPath (Join-Path $_ "yvals_core.h") })[0]
if (-not $msvc) { throw "Selected MSVC headers are missing from INCLUDE: $env:INCLUDE" }

# Exercise the actual Swift Build driver (including its argument rewriting and
# subprocess environment), without resolving or compiling the app's dependencies.
$probe = Join-Path $env:RUNNER_TEMP ("bridge-compiler-" + [guid]::NewGuid().ToString("N"))
try {
  New-Item -ItemType Directory -Path "$probe/Sources/STL/include", "$probe/Sources/SwiftProbe" -Force | Out-Null
  @'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CompilerProbe", targets: [
    .target(name: "STL"), .target(name: "SwiftProbe", dependencies: ["STL"])
])
'@ | Set-Content -LiteralPath "$probe/Package.swift"
  Set-Content -LiteralPath "$probe/Sources/STL/probe.cpp" -Value '#include <memory>'
  Set-Content -LiteralPath "$probe/Sources/SwiftProbe/probe.swift" -Value "import vcruntime`npublic let value: UInt32 = 1"
  $output = @(& swift build --package-path $probe --target SwiftProbe -c release -v @arguments `
    -Xswiftc -Rmodule-loading 2>&1)
  if ($LASTEXITCODE -ne 0) {
    $output | ForEach-Object { Write-Host $_ }
    throw "Windows compiler probe failed ($Architecture). INCLUDE=$env:INCLUDE"
  }
  $loaded = @($output | Select-String -SimpleMatch "loaded module 'vcruntime'; source:")
  $expectedMap = (Join-Path $msvc "module.modulemap").Replace('\', '/')
  if (-not $loaded -or -not (($loaded -join "`n").Replace('\', '/').Contains(
        "source: '$expectedMap'", [StringComparison]::OrdinalIgnoreCase))) {
    throw "Expected vcruntime from $expectedMap. Swift reported: $($loaded -join ' ')"
  }
  Write-Host "Verified C++ STL and Swift vcruntime ($expectedMap) for $Architecture."
} finally {
  if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Recurse -Force }
}

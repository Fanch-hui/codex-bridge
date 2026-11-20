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
  $version = Select-String -LiteralPath (Join-Path $msvc "yvals_core.h") `
    -Pattern '^\s*#\s*define\s+_MSVC_STL_UPDATE\s+(\d+)' | Select-Object -First 1
  if (-not $version) { throw "Cannot identify selected STL version under $msvc." }
  Set-Content -LiteralPath "$probe/Sources/STL/probe.cpp" -Value @"
#include <memory>
static_assert(_MSVC_STL_UPDATE == $($version.Matches[0].Groups[1].Value), "Unexpected MSVC STL version");
"@
  Set-Content -LiteralPath "$probe/Sources/SwiftProbe/probe.swift" -Value "import vcruntime`npublic let value: UInt32 = 1"
  $output = @(& swift build --package-path $probe --scratch-path "$probe/.build" --target SwiftProbe -c release -v @arguments 2>&1)
  if ($LASTEXITCODE -ne 0) {
    $output | ForEach-Object { Write-Host $_ }
    throw "Windows compiler probe failed ($Architecture). INCLUDE=$env:INCLUDE"
  }
  # Swift Build can suppress remarks for a successful compilation. Inspect its
  # compiler-produced inputs instead of depending on a particular log message.
  $files = @(Get-ChildItem "$probe/.build" -Recurse -File -Filter "*.d" | Where-Object { $_.FullName -like "*SwiftProbe.build*" })
  $used = @($files | ForEach-Object {
    (Get-Content -Raw -LiteralPath $_.FullName).Replace('\ ', ' ').Replace('\:', ':').Replace('\\', '\').Replace('\', '/')
  }) -join "`n"
  $headers = $msvc.Replace('\', '/')
  if (-not $used.Contains("$headers/module.modulemap", [StringComparison]::OrdinalIgnoreCase) -and
      -not $used.Contains("$headers/vcruntime.h", [StringComparison]::OrdinalIgnoreCase)) {
    $clang = Join-Path (Split-Path (Get-Command swift).Source) "clang.exe"
    $modules = @(Get-ChildItem "$probe/.build" -Recurse -File -Filter "vcruntime*.pcm")
    if (-not $modules) { throw "Missing vcruntime module or dependencies for $headers. Dependencies: $used" }
    foreach ($module in $modules) {
      $info = @(& $clang -module-file-info $module.FullName 2>&1)
      $map = $info | Select-String -Pattern '^\s*Module map file:\s*(.+?)\s*$' | Select-Object -First 1
      if ($LASTEXITCODE -ne 0 -or -not $map -or
          $map.Matches[0].Groups[1].Value.Replace('\', '/') -ine "$headers/module.modulemap") {
        throw "Unexpected module map for $($module.FullName): $map (expected $headers/module.modulemap)"
      }
    }
  }
  Write-Host "Verified C++ STL and imported Swift vcruntime for $Architecture ($headers)."
} finally {
  if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Recurse -Force }
}

function Get-WindowsSwiftArguments {
  param(
    [Parameter(Mandatory)][string]$VcpkgInstalledRoot,
    [string]$TargetTriple = "",
    [string[]]$LibraryPaths = @(),
    [string]$SDKRoot = $env:SDKROOT,
    [string[]]$IncludePaths = ($env:INCLUDE -split ';')
  )

  $triplet = Split-Path -Leaf $VcpkgInstalledRoot.TrimEnd('\', '/')
  $expectedTriple = switch ($triplet) {
    "x64-windows" { "x86_64-unknown-windows-msvc" }
    "arm64-windows" { "aarch64-unknown-windows-msvc" }
    default { throw "Unsupported Windows vcpkg triplet: $triplet" }
  }
  if ($TargetTriple -and $TargetTriple -ne $expectedTriple) {
    throw "Swift target $TargetTriple does not match vcpkg triplet $triplet."
  }
  $includeDirectory = Join-Path $VcpkgInstalledRoot "include"
  $arguments = @(
    "-Xswiftc", "-DSQLITE_DISABLE_SNAPSHOT",
    "-Xswiftc", "-I$includeDirectory",
    "-Xcc", "-DNOMINMAX",
    "-Xcc", "-I$includeDirectory",
    "-Xcxx", "-I$includeDirectory",
    "--build-system", "swiftbuild",
    "--triple", $expectedTriple
  )
  # Get-WindowsBuildEnvironment supplies <VC>/include and <Kit>/Include/<version>/ucrt first.
  $systemIncludes = @($IncludePaths | Where-Object { $_ -and $_ -ne $includeDirectory })
  if ($systemIncludes.Count -lt 2 -or (Split-Path -Leaf $systemIncludes[0]) -ne "include" -or
      (Split-Path -Leaf $systemIncludes[1]) -ne "ucrt") {
    throw "Expected the selected MSVC include and Windows SDK ucrt directories first in INCLUDE."
  }
  # Do not pass -idirafter paths through -Xswiftc -Xcc. SwiftPM rewrites them to
  # forward slashes, while Swift driver path options are rendered as native Windows paths.
  $kitVersionDir = Split-Path -Parent $systemIncludes[1]
  $arguments += @(
    "-Xswiftc", "-visualc-tools-root", "-Xswiftc", (Split-Path -Parent $systemIncludes[0]),
    "-Xswiftc", "-windows-sdk-root", "-Xswiftc", (Split-Path -Parent (Split-Path -Parent $kitVersionDir)),
    "-Xswiftc", "-windows-sdk-version", "-Xswiftc", (Split-Path -Leaf $kitVersionDir)
  )
  $headerFlags = @("-nostdlibinc") + @($systemIncludes | ForEach-Object { "-idirafter$_" })
  foreach ($flag in $headerFlags) {
    $arguments += @("-Xcc", $flag, "-Xcxx", $flag)
  }
  if ($SDKRoot) {
    $arguments += @("--sdk", $SDKRoot)
  }
  $paths = @(Join-Path $VcpkgInstalledRoot "lib") + $LibraryPaths
  foreach ($libraryPath in ($paths | Where-Object { $_ } | Select-Object -Unique)) {
    $arguments += @("-Xlinker", "-libpath:$libraryPath")
  }
  return $arguments
}

function Get-WindowsSwiftArguments {
  param(
    [Parameter(Mandatory)][string]$VcpkgInstalledRoot,
    [string]$TargetTriple = "",
    [string[]]$LibraryPaths = @(),
    [string]$SDKRoot = $env:SDKROOT
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
    "-Xswiftc", "-Xcc", "-Xswiftc", "-I$includeDirectory",
    "-Xcc", "-DNOMINMAX",
    "-Xcc", "-I$includeDirectory",
    "--build-system", "swiftbuild",
    "--triple", $expectedTriple
  )
  if ($SDKRoot) {
    $arguments += @("--sdk", $SDKRoot)
  }
  $paths = @(Join-Path $VcpkgInstalledRoot "lib") + $LibraryPaths
  foreach ($libraryPath in ($paths | Where-Object { $_ } | Select-Object -Unique)) {
    $arguments += @("-Xlinker", "-libpath:$libraryPath")
  }
  return $arguments
}

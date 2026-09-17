function Get-WindowsSwiftArguments {
  param(
    [Parameter(Mandatory)][string]$VcpkgInstalledRoot,
    [string]$TargetTriple = "",
    [string[]]$LibraryPaths = @()
  )

  $includeDirectory = Join-Path $VcpkgInstalledRoot "include"
  $arguments = @(
    "-Xswiftc", "-DSQLITE_DISABLE_SNAPSHOT",
    "-Xswiftc", "-I$includeDirectory",
    "-Xswiftc", "-Xcc", "-Xswiftc", "-I$includeDirectory",
    "-Xcc", "-DNOMINMAX",
    "-Xcc", "-I$includeDirectory",
    "--build-system", "swiftbuild"
  )
  if ($TargetTriple) {
    $arguments += @("--triple", $TargetTriple)
  }
  $paths = @(Join-Path $VcpkgInstalledRoot "lib") + $LibraryPaths
  foreach ($libraryPath in ($paths | Where-Object { $_ } | Select-Object -Unique)) {
    $arguments += @("-Xlinker", "-libpath:$libraryPath")
  }
  return $arguments
}

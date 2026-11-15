function Get-CompatibleWindowsMSVCRoot {
  param(
    [Parameter(Mandatory)][string]$Directory,
    [Parameter(Mandatory)][ValidateSet("x64", "arm64")][string]$Architecture
  )

  # Swift 6.3.3 embeds Clang 21; later MSVC STL releases can require a newer Clang.
  Get-ChildItem -LiteralPath $Directory -Directory |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+(\.\d+)?$' } |
    Where-Object { [version]$_.Name -lt [version]"14.45" } |
    Sort-Object { [version]$_.Name } -Descending |
    Where-Object {
      (Test-Path -LiteralPath (Join-Path $_.FullName "include\yvals_core.h") -PathType Leaf) -and
      (Test-Path -LiteralPath (Join-Path $_.FullName "lib\$Architecture\libcmt.lib") -PathType Leaf)
    } |
    Select-Object -First 1 -ExpandProperty FullName
}

function Get-WindowsBuildEnvironment {
  param(
    [Parameter(Mandatory)][ValidateSet("x64", "arm64")][string]$Architecture
  )

  $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
  if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw "Visual Studio vswhere.exe is required to resolve target libraries."
  }
  $vsOutput = @(& $vswhere -latest -property installationPath)
  $vsRoot = $vsOutput | Select-Object -First 1
  if ($LASTEXITCODE -ne 0 -or -not $vsRoot) {
    throw "Visual Studio installation was not found."
  }
  $msvcRoot = Get-CompatibleWindowsMSVCRoot -Directory (Join-Path $vsRoot "VC\Tools\MSVC") `
    -Architecture $Architecture
  if (-not $msvcRoot) {
    throw "MSVC 14.44 or earlier C++ headers and libraries for $Architecture are required for Swift 6.3.3."
  }

  $kitsRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10"
  $sdkVersion = Get-ChildItem (Join-Path $kitsRoot "Lib") -Directory |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+(\.\d+)?$' } |
    Sort-Object { [version]$_.Name } -Descending |
    Where-Object {
      (Test-Path (Join-Path $_.FullName "um\$Architecture\kernel32.lib")) -and
      (Test-Path (Join-Path $_.FullName "ucrt\$Architecture\ucrt.lib")) -and
      (Test-Path (Join-Path $kitsRoot "Include\$($_.Name)\um\Windows.h"))
    } | Select-Object -First 1 -ExpandProperty Name
  if (-not $sdkVersion) {
    throw "Windows SDK headers and libraries for $Architecture are required."
  }
  $sdkInclude = Join-Path $kitsRoot "Include\$sdkVersion"
  $sdkLibrary = Join-Path $kitsRoot "Lib\$sdkVersion"
  $hostBinDir = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "Hostarm64" } else { "Hostx64" }
  $msvcBin = Join-Path $msvcRoot "bin\$hostBinDir\$Architecture"
  if (-not (Test-Path -LiteralPath $msvcBin -PathType Container)) {
    $msvcBin = Join-Path $msvcRoot "bin\Hostx64\$Architecture"
  }
  $sdkBin = Join-Path $kitsRoot "bin\$sdkVersion\$Architecture"
  $binaryPaths = @($msvcBin, $sdkBin) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }
  return [PSCustomObject]@{
    BinaryPaths = $binaryPaths
    IncludePaths = @(
      "$msvcRoot\include", "$sdkInclude\ucrt", "$sdkInclude\um",
      "$sdkInclude\shared", "$sdkInclude\winrt"
    )
    LibraryPaths = @(
      "$msvcRoot\lib\$Architecture", "$sdkLibrary\um\$Architecture",
      "$sdkLibrary\ucrt\$Architecture"
    )
  }
}

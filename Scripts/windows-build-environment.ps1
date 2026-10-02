function Get-WindowsBuildEnvironment {
  param(
    [Parameter(Mandatory)][ValidateSet("x64", "arm64")][string]$Architecture
  )

  $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
  if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw "Visual Studio vswhere.exe is required to resolve target libraries."
  }
  $vsRoot = & $vswhere -latest -property installationPath | Select-Object -First 1
  if ($LASTEXITCODE -ne 0 -or -not $vsRoot) {
    throw "Visual Studio installation was not found."
  }
  $msvcRoot = Get-ChildItem (Join-Path $vsRoot "VC\Tools\MSVC") -Directory |
    Sort-Object { [version]$_.Name } -Descending |
    Where-Object { Test-Path (Join-Path $_.FullName "lib\$Architecture\libcmt.lib") } |
    Select-Object -First 1 -ExpandProperty FullName
  if (-not $msvcRoot) {
    throw "Visual Studio C++ libraries for $Architecture are required."
  }

  $kitsRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10"
  $sdkVersion = Get-ChildItem (Join-Path $kitsRoot "Lib") -Directory |
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
  return [PSCustomObject]@{
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

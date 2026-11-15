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

function Get-WindowsMSVCIncludePath {
  param(
    [Parameter(Mandatory)][string]$IncludeDirectory,
    [Parameter(Mandatory)][string]$SDKRoot,
    [Parameter(Mandatory)][string]$StagingDirectory
  )

  $moduleMap = Join-Path $SDKRoot "usr\share\vcruntime.modulemap"
  $apiNotes = Join-Path $SDKRoot "usr\share\vcruntime.apinotes"
  foreach ($path in @($moduleMap, $apiNotes)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Swift SDK MSVC module support file is missing: $path"
    }
  }

  $installedModuleMap = Join-Path $IncludeDirectory "module.modulemap"
  $installedApiNotes = Join-Path $IncludeDirectory "vcruntime.apinotes"
  # Swift installs these files for one MSVC toolset; the compatible toolset can be another version.
  if ((Test-Path -LiteralPath $installedModuleMap -PathType Leaf) -and
      (Test-Path -LiteralPath $installedApiNotes -PathType Leaf) -and
      (Get-FileHash -LiteralPath $installedModuleMap).Hash -eq (Get-FileHash -LiteralPath $moduleMap).Hash -and
      (Get-FileHash -LiteralPath $installedApiNotes).Hash -eq (Get-FileHash -LiteralPath $apiNotes).Hash) {
    return $IncludeDirectory
  }

  if (Test-Path -LiteralPath $StagingDirectory) {
    throw "MSVC include staging directory already exists: $StagingDirectory"
  }
  try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $StagingDirectory) -Force | Out-Null
    Copy-Item -LiteralPath $IncludeDirectory -Destination $StagingDirectory -Recurse
    Copy-Item -LiteralPath $moduleMap -Destination (Join-Path $StagingDirectory "module.modulemap") -Force
    Copy-Item -LiteralPath $apiNotes -Destination (Join-Path $StagingDirectory "vcruntime.apinotes") -Force
  } catch {
    if (Test-Path -LiteralPath $StagingDirectory) {
      Remove-Item -LiteralPath $StagingDirectory -Recurse -Force
    }
    throw
  }
  return $StagingDirectory
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

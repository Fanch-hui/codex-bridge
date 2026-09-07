# Compiles native Windows resources used by the desktop application.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path Env:OS) -or $env:OS -ne "Windows_NT") {
  throw "Scripts\compile-windows-resources.ps1 must run on Windows."
}

$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$buildRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot ".build"))
$outputFull = if ([IO.Path]::IsPathRooted($OutputPath)) {
  [IO.Path]::GetFullPath($OutputPath)
} else {
  [IO.Path]::GetFullPath((Join-Path $repoRoot $OutputPath))
}
$buildComparable = ($buildRoot -replace "/", "\").TrimEnd("\")
$outputComparable = ($outputFull -replace "/", "\").TrimEnd("\")
if (-not $outputComparable.Equals($buildComparable, [StringComparison]::OrdinalIgnoreCase) -and
    -not $outputComparable.StartsWith("$buildComparable\", [StringComparison]::OrdinalIgnoreCase)) {
  throw "OutputPath must be inside the repository .build directory."
}

$sourceRelative = "Windows\CodexBridgeWindowsApp.rc"
$sourceFull = Join-Path $repoRoot "Packages\BridgeCore\$sourceRelative"
if (-not (Test-Path -LiteralPath $sourceFull -PathType Leaf)) {
  throw "Windows application resource source is missing: $sourceFull"
}

function Resolve-ResourceCompiler {
  $commands = @(
    (Get-Command "llvm-rc.exe" -ErrorAction SilentlyContinue | Select-Object -First 1),
    (Get-Command "rc.exe" -ErrorAction SilentlyContinue | Select-Object -First 1)
  )
  foreach ($command in $commands) {
    if ($command -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
      return $command.Source
    }
  }

  $roots = @(
    (Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"),
    (Join-Path $env:ProgramFiles "Windows Kits\10\bin")
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) }
  $candidates = foreach ($root in $roots) {
    Get-ChildItem -LiteralPath $root -File -Recurse -Filter "rc.exe" -ErrorAction SilentlyContinue |
      Sort-Object FullName -Descending
  }
  $compiler = $candidates | Select-Object -First 1
  if ($compiler) {
    return $compiler.FullName
  }
  throw "Neither llvm-rc.exe nor the Windows SDK rc.exe was found."
}

$compiler = Resolve-ResourceCompiler
$outputDirectory = Split-Path -Parent $outputFull
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
  New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
if (Test-Path -LiteralPath $outputFull) {
  $existing = Get-Item -LiteralPath $outputFull -Force
  if ($existing.PSIsContainer -or
      (($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
    throw "Resource output is not a regular file: $outputFull"
  }
  Remove-Item -LiteralPath $outputFull -Force
}

Push-Location (Join-Path $repoRoot "Packages\BridgeCore")
try {
  & $compiler /FO $outputFull $sourceRelative
  if ($LASTEXITCODE -ne 0) {
    throw "Windows resource compiler failed."
  }
} finally {
  Pop-Location
}

if (-not (Test-Path -LiteralPath $outputFull -PathType Leaf)) {
  throw "Windows resource compiler did not produce: $outputFull"
}
Write-Host "Windows resources: $outputFull"

#if os(Windows)
  import Foundation

  enum WindowsPortableUpdateHelper {
    static var powerShellPath: String {
      let root = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
      return root + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
    }

    static func writeScript(to url: URL) throws {
      try Data(script.utf8).write(to: url, options: .atomic)
    }

    private static let script = #"""
      param(
        [Parameter(Mandatory = $true)][string]$Config,
        [switch]$Prepare,
        [switch]$InstallerCleanup
      )
      $ErrorActionPreference = "Stop"
      $c = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json

      function Root([string]$path) {
        [IO.Path]::GetFullPath($path).TrimEnd('\').ToLowerInvariant()
      }

      function Safe([string]$root, [string]$relative) {
        $value = $relative.Replace('/', '\')
        if ([IO.Path]::IsPathRooted($value) -or $value.Contains(':') -or
            $value -match '(^|\\)\.\.?($|\\)') {
          throw "Unsafe update path."
        }
        $candidate = [IO.Path]::GetFullPath((Join-Path $root $value))
        if (-not (Root $candidate).StartsWith((Root $root) + '\')) {
          throw "Update path escaped its root."
        }
        $candidate
      }

      function NoReparse([string]$root, [string]$path) {
        $rootPath = Root $root
        $cursor = [IO.Path]::GetFullPath($path)
        while ((Root $cursor).StartsWith($rootPath)) {
          if (-not (Test-Path -LiteralPath $cursor)) {
            $missingParent = [IO.Directory]::GetParent($cursor)
            if ($null -eq $missingParent) { break }
            $cursor = $missingParent.FullName
            continue
          }
          $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
          if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse point in update directory."
          }
          if ((Root $cursor) -eq $rootPath) { return }
          $parent = [IO.Directory]::GetParent($cursor)
          if ($null -eq $parent) { break }
          $cursor = $parent.FullName
        }
        throw "Update directory is outside its root."
      }

      function Manifest([string]$root, [string]$name) {
        $path = Safe $root $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
          throw "Missing update manifest."
        }
        $entries = @{}
        foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
          if ($line -notmatch '^([0-9a-fA-F]{64})  (.+)$') {
            throw "Invalid update manifest."
          }
          $hash = $Matches[1]
          $relative = $Matches[2].Replace('/', '\')
          $key = $relative.ToLowerInvariant()
          if ($entries.ContainsKey($key)) { throw "Duplicate update path." }
          $file = Safe $root $relative
          if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Incomplete update payload."
          }
          $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
          if ($actual -ne $hash.ToLowerInvariant()) { throw "Invalid update checksum." }
          $entries[$key] = $relative
        }
        $entries[$name.ToLowerInvariant()] = $name
        $entries
      }

      function ReadOldManifest([string]$root, [string]$name) {
        $entries = @{}
        $path = Join-Path $root $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $entries }
        foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
          if ($line -notmatch '^[0-9a-fA-F]{64}  (.+)$') {
            throw "Invalid installed manifest."
          }
          $relative = $Matches[1].Replace('/', '\')
          if ([IO.Path]::IsPathRooted($relative) -or $relative.Contains(':') -or
              $relative -match '(^|\\)\.\.?($|\\)') {
            throw "Invalid installed manifest."
          }
          $entries[$relative.ToLowerInvariant()] = $relative
        }
        $entries
      }

      function WriteReceipt([string]$message) {
        if ([string]::IsNullOrWhiteSpace($c.failureReceiptPath)) { return }
        $receipt = @{
          schema = "codex-bridge-update-failure/v1"
          message = $message
          timestamp = [DateTimeOffset]::UtcNow.ToString("O")
        } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText(
          $c.failureReceiptPath,
          $receipt + [Environment]::NewLine,
          [Text.UTF8Encoding]::new($false)
        )
      }

      function StopService([string]$path) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
        $process = Start-Process -FilePath $path -ArgumentList @('--shutdown') -WorkingDirectory $c.applicationDirectory -PassThru -WindowStyle Hidden
        if (-not $process.WaitForExit(30000) -or $process.ExitCode -ne 0) {
          throw "Service did not stop cleanly."
        }
      }

      function WaitApp([UInt32]$id) {
        $process = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($null -ne $process -and -not $process.WaitForExit(30000)) {
          throw "Application did not exit."
        }
      }

      function Cleanup([string]$path) {
        if (Test-Path -LiteralPath $path) {
          Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
      }

      if ($Prepare) {
        $staging = [IO.Path]::GetFullPath($c.stagingPath)
        Cleanup $staging
        [IO.Directory]::CreateDirectory($staging) | Out-Null
        Expand-Archive -LiteralPath $c.packagePath -DestinationPath $staging -Force
        NoReparse $staging $staging
        $files = Manifest $staging $c.payloadManifest
        $application = Safe $staging 'codex-bridge-windows-app.exe'
        if (-not (Test-Path -LiteralPath $application -PathType Leaf)) {
          throw "Missing desktop application."
        }
        return
      }

      if ($InstallerCleanup) {
        try {
          $installer = Get-Process -Id ([UInt32]$c.installerProcessID) -ErrorAction SilentlyContinue
          if ($null -ne $installer -and -not $installer.WaitForExit(120000)) {
            throw "Installer did not exit."
          }
          $infoPath = Join-Path $c.applicationDirectory 'BUILD-INFO.json'
          $info = Get-Content -LiteralPath $infoPath -Raw -Encoding UTF8 | ConvertFrom-Json
          if (-not [string]::Equals([string]$info.appVersion, [string]$c.expectedVersion, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Installed version did not match the update."
          }
        } catch {
          WriteReceipt $_.Exception.Message
          if (Test-Path -LiteralPath $c.applicationExecutable -PathType Leaf) {
            Start-Process -FilePath $c.applicationExecutable -WorkingDirectory $c.applicationDirectory
          }
        } finally {
          Cleanup (Split-Path -Parent $Config)
          Cleanup (Split-Path -Parent $c.packagePath)
        }
        return
      }

      $root = [IO.Path]::GetFullPath($c.applicationDirectory)
      $staging = [IO.Path]::GetFullPath($c.stagingPath)
      $backup = Join-Path ([IO.Path]::GetTempPath()) ("CodexBridgeRollback-" + [Guid]::NewGuid().ToString('N'))
      $newFiles = @{}
      $oldFiles = @{}
      $backupFiles = @{}
      $replacementStarted = $false
      try {
        NoReparse $root $root
        WaitApp ([UInt32]$c.processID)
        StopService $c.serviceExecutable
        if (-not (Test-Path -LiteralPath $staging -PathType Container)) {
          throw "Missing prepared update payload."
        }
        $newFiles = Manifest $staging $c.payloadManifest
        $application = Safe $staging 'codex-bridge-windows-app.exe'
        if (-not (Test-Path -LiteralPath $application -PathType Leaf)) {
          throw "Missing desktop application."
        }
        $oldFiles = ReadOldManifest $root $c.payloadManifest
        [IO.Directory]::CreateDirectory($backup) | Out-Null
        $candidates = @(
          @($oldFiles.Values) + @($newFiles.Values) +
          @('codex-bridge-windows-app.exe', 'codex-bridge-service.exe', $c.payloadManifest)
        ) | Sort-Object -Unique
        foreach ($relative in $candidates) {
          $source = Safe $root $relative
          if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
          NoReparse $root $source
          $destination = Safe $backup $relative
          $parent = [IO.Path]::GetDirectoryName($destination)
          [IO.Directory]::CreateDirectory($parent) | Out-Null
          Copy-Item -LiteralPath $source -Destination $destination -Force
          $backupFiles[$relative.ToLowerInvariant()] = $relative
        }
        $replacementStarted = $true
        foreach ($key in $newFiles.Keys) {
          $source = Safe $staging $newFiles[$key]
          $destination = Safe $root $newFiles[$key]
          $parent = [IO.Path]::GetDirectoryName($destination)
          NoReparse $root $destination
          [IO.Directory]::CreateDirectory($parent) | Out-Null
          Copy-Item -LiteralPath $source -Destination $destination -Force
        }
        foreach ($key in $oldFiles.Keys) {
          if ($newFiles.ContainsKey($key)) { continue }
          $obsolete = Safe $root $oldFiles[$key]
          NoReparse $root $obsolete
          if (Test-Path -LiteralPath $obsolete -PathType Leaf) { Remove-Item -LiteralPath $obsolete -Force }
        }
        Start-Process -FilePath $c.applicationExecutable -WorkingDirectory $root
      } catch {
        $failureMessage = $_.Exception.Message
        try {
          if ($replacementStarted) {
            foreach ($key in $newFiles.Keys) {
              if ($backupFiles.ContainsKey($key)) { continue }
              $newPath = Safe $root $newFiles[$key]
              if (Test-Path -LiteralPath $newPath -PathType Leaf) { Remove-Item -LiteralPath $newPath -Force }
            }
            foreach ($key in $backupFiles.Keys) {
              $source = Safe $backup $backupFiles[$key]
              $destination = Safe $root $backupFiles[$key]
              $parent = [IO.Path]::GetDirectoryName($destination)
              [IO.Directory]::CreateDirectory($parent) | Out-Null
              Copy-Item -LiteralPath $source -Destination $destination -Force
            }
          }
        } catch {
          $failureMessage += " Update rollback failed: " + $_.Exception.Message
        }
        WriteReceipt $failureMessage
        if (Test-Path -LiteralPath $c.applicationExecutable -PathType Leaf) {
          Start-Process -FilePath $c.applicationExecutable -WorkingDirectory $root
        }
      } finally {
        Cleanup $backup
        Cleanup (Split-Path -Parent $Config)
        Cleanup (Split-Path -Parent $c.packagePath)
      }
      """#
  }
#endif

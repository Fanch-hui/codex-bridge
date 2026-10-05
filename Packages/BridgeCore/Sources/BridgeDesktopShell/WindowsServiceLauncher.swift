#if os(Windows)
  import BridgeIPC
  import BridgeServiceAppCore
  import Foundation
  import WinSDK

  /// Ensures the background service (`codex-bridge-service.exe`, built from
  /// the same package) is listening on the IPC pipe, launching it detached
  /// from the shell's own directory when it is not. The launch is hardened
  /// against crash-loop feedback: the service inherits a headless error mode
  /// (no WER dialogs), starts with an explicit working directory, and its
  /// stderr is captured to a bootstrap log so startup failures of the
  /// detached process stay diagnosable. A process that exits before
  /// listening is reported immediately instead of polling to the end of the
  /// readiness window.
  enum WindowsServiceLauncher {
    private static let serviceExecutableName = "codex-bridge-service.exe"
    private static let pipeReadyPollCount = 50
    private static let pipeReadyPollIntervalMs: DWORD = 200
    // STARTF_USESTDHANDLES.
    private static let startfUseStdHandles: DWORD = 0x0000_0100
    // FILE_END, used to append to the bootstrap log.
    private static let seekFileEnd: DWORD = 2

    /// Returns the outcome of making the service pipe available, launching
    /// the service first when required. Blocks for up to ~10s while polling
    /// for readiness, and returns as soon as a launched process exits.
    static func ensureServiceRunning() -> ServiceLaunchOutcome {
      if isPipeAvailable() { return .ready }
      guard let executablePath = serviceExecutablePath() else {
        return .launchFailed(systemError: Int(GetLastError()))
      }
      switch launchServiceProcess(executablePath: executablePath) {
      case .failed(let systemError):
        return .launchFailed(systemError: systemError)
      case .running(let process):
        defer { _ = CloseHandle(process) }
        for _ in 0..<pipeReadyPollCount {
          let waitResult = WaitForSingleObject(process, pipeReadyPollIntervalMs)
          if waitResult == WAIT_OBJECT_0 {
            var exitCode: DWORD = 0
            _ = GetExitCodeProcess(process, &exitCode)
            return .exitedDuringStartup(exitCode: Int(exitCode))
          }
          if isPipeAvailable() { return .ready }
        }
        return .readinessTimeout
      }
    }

    /// Opening the pipe with the same access the real client uses both probes
    /// the server and (on ERROR_PIPE_BUSY) proves one exists.
    static func isPipeAvailable() -> Bool {
      BridgeServiceIPC.windowsPipeName.withCString(encodedAs: UTF16.self) { name in
        let handle = CreateFileW(
          name,
          // GENERIC_READ | GENERIC_WRITE
          DWORD(0x8000_0000) | DWORD(0x4000_0000),
          0,
          nil,
          DWORD(OPEN_EXISTING),
          0,
          nil
        )
        if handle == INVALID_HANDLE_VALUE {
          return GetLastError() == ERROR_PIPE_BUSY
        }
        _ = CloseHandle(handle)
        return true
      }
    }

    /// Path of the bootstrap log the service's stderr is redirected to. The
    /// directory matches `ServiceDataPaths.defaultRoot()` so the service and
    /// the shell agree on where startup diagnostics live.
    static var bootstrapLogURL: URL? {
      guard
        let support = FileManager.default.urls(
          for: .applicationSupportDirectory, in: .userDomainMask
        ).first
      else { return nil }
      return support
        .appending(path: "CodexBridgeService", directoryHint: .isDirectory)
        .appending(path: "Logs", directoryHint: .isDirectory)
        .appending(path: "service-bootstrap.log")
    }

    private enum LaunchedProcess {
      case running(HANDLE)
      case failed(systemError: Int)
    }

    private static func launchServiceProcess(executablePath: String) -> LaunchedProcess {
      var startupInfo = STARTUPINFOW()
      startupInfo.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
      var processInfo = PROCESS_INFORMATION()
      var commandLine = Array("\"\(executablePath)\"".utf16) + [WCHAR(0)]
      // The launcher derives the service path from this executable's own
      // directory, so the separator always exists and the child never
      // inherits a stale working directory from the shell.
      guard let separator = executablePath.lastIndex(of: "\\") else {
        return .failed(systemError: Int(GetLastError()))
      }
      let workingDirectory = String(executablePath[..<separator])

      // Capture the service's stderr so a startup failure of the detached
      // process remains diagnosable. Best effort: the launch proceeds
      // without the log when it cannot be opened.
      let stderrHandle = openBootstrapLogHandle()
      defer { if let stderrHandle { _ = CloseHandle(stderrHandle) } }
      if let stderrHandle {
        startupInfo.dwFlags |= startfUseStdHandles
        startupInfo.hStdError = stderrHandle
      }

      // Keep hard-error and WER popups out of the user session: the error
      // mode is inherited by the child, so a crashing service cannot raise
      // "stopped working" dialogs in a loop.
      let previousErrorMode = SetErrorMode(
        UINT(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX))
      defer { _ = SetErrorMode(previousErrorMode) }

      let launched = executablePath.withCString(encodedAs: UTF16.self) { applicationName in
        commandLine.withUnsafeMutableBufferPointer { commandLine in
          workingDirectory.withCString(encodedAs: UTF16.self) { currentDirectory in
            CreateProcessW(
              applicationName,
              commandLine.baseAddress,
              nil,
              nil,
              stderrHandle != nil,
              DWORD(CREATE_NO_WINDOW) | DWORD(DETACHED_PROCESS),
              nil,
              currentDirectory,
              &startupInfo,
              &processInfo
            )
          }
        }
      }
      guard launched else { return .failed(systemError: Int(GetLastError())) }
      _ = CloseHandle(processInfo.hThread)
      return .running(processInfo.hProcess)
    }

    private static func openBootstrapLogHandle() -> HANDLE? {
      guard let logURL = bootstrapLogURL else { return nil }
      do {
        try FileManager.default.createDirectory(
          at: logURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
      } catch {
        return nil
      }
      var inheritable = SECURITY_ATTRIBUTES()
      inheritable.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
      inheritable.bInheritHandle = true
      let handle = logURL.path.withCString(encodedAs: UTF16.self) { path in
        CreateFileW(
          path,
          DWORD(GENERIC_WRITE),
          DWORD(FILE_SHARE_READ),
          &inheritable,
          DWORD(OPEN_ALWAYS),
          DWORD(FILE_ATTRIBUTE_NORMAL),
          nil
        )
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else { return nil }
      // Append so repeated launches accumulate history instead of
      // truncating the previous crash's output.
      _ = SetFilePointer(handle, 0, nil, seekFileEnd)
      let marker = "=== codex-bridge-service launch \(ISO8601DateFormatter().string(from: Date())) ===\r\n"
      let bytes = Array(marker.utf8)
      var written: DWORD = 0
      bytes.withUnsafeBufferPointer { raw in
        _ = WriteFile(handle, raw.baseAddress, DWORD(bytes.count), &written, nil)
      }
      return handle
    }

    private static func serviceExecutablePath() -> String? {
      var buffer = [WCHAR](repeating: 0, count: 1024)
      let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
      guard length > 0, length < DWORD(buffer.count) else { return nil }
      let executable = String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
      guard let directoryEnd = executable.lastIndex(of: "\\") else { return nil }
      return String(executable[..<directoryEnd]) + "\\" + serviceExecutableName
    }
  }
#endif

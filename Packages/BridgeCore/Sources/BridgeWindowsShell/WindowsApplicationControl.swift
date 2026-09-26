#if os(Windows)
  import Foundation
  import WinSDK

  enum WindowsApplicationIdentity {
    static let mainWindowClassName = "CodexBridgeMainWindow"
    static let explicitCloseRequest = WPARAM(1)
    static let restoreRequest = UINT(WM_APP + 42)
  }

  public enum WindowsApplicationControl {
    public static func ensureServiceRunning() -> Bool {
      WindowsServiceLauncher.ensureServiceRunning()
    }

    /// Returns false when another copy already owns the session; that copy is restored.
    public static func claimInstanceOrActivateExisting() -> Bool {
      let mutexName = "Local\\CodexBridge.WindowsApp.SingleInstance"
      SetLastError(0)
      let created = mutexName.withCString(encodedAs: UTF16.self) {
        CreateMutexW(nil, true, $0)
      }
      guard let created else { return true }
      if GetLastError() == DWORD(ERROR_ALREADY_EXISTS) {
        _ = CloseHandle(created)
        activateExistingMainWindow()
        return false
      }
      instanceMutex = created
      return true
    }

    public static func shutdownRunningApplication() -> Bool {
      guard let expectedPath = currentExecutablePath() else { return false }
      var closedCount = 0
      while let window = findMainWindow(for: expectedPath) {
        guard closedCount < 16, close(window: window, expectedPath: expectedPath) else {
          return false
        }
        closedCount += 1
      }
      return true
    }

    private static func close(window: HWND, expectedPath: String) -> Bool {
      var processID: DWORD = 0
      guard GetWindowThreadProcessId(window, &processID) != 0, processID > 0 else { return false }
      let access = DWORD(PROCESS_QUERY_LIMITED_INFORMATION) | DWORD(SYNCHRONIZE)
      guard let process = OpenProcess(access, false, processID) else { return false }
      defer { _ = CloseHandle(process) }
      guard processImagePath(process)?.caseInsensitiveCompare(expectedPath) == .orderedSame else {
        return false
      }
      if !PostMessageW(window, UINT(WM_CLOSE), WindowsApplicationIdentity.explicitCloseRequest, 0),
        WaitForSingleObject(process, 0) != WAIT_OBJECT_0
      {
        return false
      }
      return WaitForSingleObject(process, 30_000) == WAIT_OBJECT_0
    }

    private static func findMainWindow(for expectedPath: String) -> HWND? {
      WindowsApplicationIdentity.mainWindowClassName.withCString(encodedAs: UTF16.self) { name in
        var previous: HWND?
        while let window = FindWindowExW(nil, previous, name, nil) {
          var processID: DWORD = 0
          if GetWindowThreadProcessId(window, &processID) != 0,
            let path = processImagePath(processID),
            path.caseInsensitiveCompare(expectedPath) == .orderedSame
          {
            return window
          }
          previous = window
        }
        return nil
      }
    }

    nonisolated(unsafe) private static var instanceMutex: HANDLE?

    private static func activateExistingMainWindow() {
      guard let expectedPath = currentExecutablePath() else { return }
      for _ in 0..<30 {
        if let window = findMainWindow(for: expectedPath) {
          var processID: DWORD = 0
          _ = GetWindowThreadProcessId(window, &processID)
          if processID > 0 {
            _ = AllowSetForegroundWindow(processID)
          }
          _ = PostMessageW(window, WindowsApplicationIdentity.restoreRequest, 0, 0)
          return
        }
        Sleep(100)
      }
    }

    private static func currentExecutablePath() -> String? {
      var buffer = [WCHAR](repeating: 0, count: 32_768)
      let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
      guard length > 0, length < DWORD(buffer.count) else { return nil }
      return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
    }

    private static func processImagePath(_ process: HANDLE) -> String? {
      var buffer = [WCHAR](repeating: 0, count: 32_768)
      var length = DWORD(buffer.count)
      guard QueryFullProcessImageNameW(process, 0, &buffer, &length), length > 0 else { return nil }
      return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
    }

    private static func processImagePath(_ processID: DWORD) -> String? {
      guard
        let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, processID)
      else { return nil }
      defer { _ = CloseHandle(process) }
      return processImagePath(process)
    }
  }
#endif

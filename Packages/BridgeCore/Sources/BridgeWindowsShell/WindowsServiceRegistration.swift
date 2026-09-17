import Foundation

public enum WindowsServiceRegistrationError: Error, LocalizedError, Sendable, Equatable {
  case executableNotFound
  case registryOpenFailed(Int32)
  case registryWriteFailed(Int32)
  case registryDeleteFailed(Int32)

  public var errorDescription: String? {
    switch self {
    case .executableNotFound:
      return "未找到 Codex Bridge 后台 Service 可执行文件。"
    case .registryOpenFailed(let code):
      return "无法打开注册表 Run 键 (错误代码 \(code))。"
    case .registryWriteFailed(let code):
      return "注册表写入自启动项失败 (错误代码 \(code))。"
    case .registryDeleteFailed(let code):
      return "注册表注销自启动项失败 (错误代码 \(code))。"
    }
  }
}

#if os(Windows)
  import WinSDK

  public struct WindowsServiceRegistration: Sendable {
    public static let runKeyPath = "Software\\Microsoft\\Windows\\CurrentVersion\\Run"
    public static let valueName = "CodexBridgeService"

    private static let keyReadAccess: REGSAM = 0x0002_0019
    private static let keyWriteAccess: REGSAM = 0x0002_0006

    nonisolated(unsafe) static var mockBackendEnabled = false
    nonisolated(unsafe) private static var mockValue: String?
    private static let mockLock = NSLock()

    public static func isRegistered(executablePath: String? = nil) -> Bool {
      if mockBackendEnabled {
        mockLock.lock()
        defer { mockLock.unlock() }
        guard let value = mockValue, !value.isEmpty else { return false }
        if let executablePath {
          return normalizePath(value) == normalizePath(executablePath)
        }
        return true
      }

      guard let registered = readRegisteredValue(), !registered.isEmpty else {
        return false
      }
      if let executablePath {
        return normalizePath(registered) == normalizePath(executablePath)
      }
      return true
    }

    public static func register(executablePath: String? = nil) throws {
      guard let path = executablePath ?? applicationExecutablePath(), !path.isEmpty else {
        throw WindowsServiceRegistrationError.executableNotFound
      }
      let value =
        executablePath == nil
        ? startupCommand(for: path)
        : formattedValue(for: path)
      if mockBackendEnabled {
        mockLock.lock()
        defer { mockLock.unlock() }
        mockValue = value
        return
      }
      try writeRegisteredValue(value)
    }

    public static func unregister() throws {
      if mockBackendEnabled {
        mockLock.lock()
        defer { mockLock.unlock() }
        mockValue = nil
        return
      }
      try deleteRegisteredValue()
    }

    public static func serviceExecutablePath() -> String? {
      guard let directory = moduleDirectory() else { return nil }
      return directory + "\\codex-bridge-service.exe"
    }

    /// Returns the GUI shell used by the Run key. Starting the console service
    /// directly from Explorer allocates a visible console for a moment.
    public static func applicationExecutablePath() -> String? {
      currentExecutablePath()
    }

    public static func startupCommand(for applicationPath: String) -> String {
      "\(formattedValue(for: applicationPath)) --ensure-service"
    }

    /// Rewrites registrations made by older builds so the next logon starts
    /// through the GUI shell and keeps the console service hidden.
    public static func migrateLegacyRegistration() {
      guard
        let registered = readRegisteredValue(),
        let service = serviceExecutablePath(),
        normalizePath(registered) == normalizePath(service),
        let application = applicationExecutablePath()
      else { return }
      try? writeRegisteredValue(startupCommand(for: application))
    }

    private static func currentExecutablePath() -> String? {
      var buffer = [WCHAR](repeating: 0, count: 1024)
      let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
      guard length > 0, length < DWORD(buffer.count) else { return nil }
      return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
    }

    private static func moduleDirectory() -> String? {
      guard let executable = currentExecutablePath(),
        let directoryEnd = executable.lastIndex(of: "\\")
      else { return nil }
      return String(executable[..<directoryEnd])
    }

    public static func resetForTesting() {
      mockLock.lock()
      defer { mockLock.unlock() }
      mockValue = nil
      mockBackendEnabled = true
    }

    public static func restoreLiveBackendForTesting() {
      mockLock.lock()
      defer { mockLock.unlock() }
      mockValue = nil
      mockBackendEnabled = false
    }

    private static func readRegisteredValue() -> String? {
      var hKey: HKEY?
      let openStatus = runKeyPath.withCString(encodedAs: UTF16.self) { subkeyPtr in
        RegOpenKeyExW(HKEY_CURRENT_USER, subkeyPtr, 0, keyReadAccess, &hKey)
      }
      guard openStatus == ERROR_SUCCESS, let key = hKey else { return nil }
      defer { RegCloseKey(key) }

      var type: DWORD = 0
      var byteCount: DWORD = 0
      let queryStatus = valueName.withCString(encodedAs: UTF16.self) { valNamePtr in
        RegQueryValueExW(key, valNamePtr, nil, &type, nil, &byteCount)
      }
      guard queryStatus == ERROR_SUCCESS, byteCount > 0, type == DWORD(REG_SZ) else {
        return nil
      }

      let wcharCount = Int(byteCount) / MemoryLayout<WCHAR>.size
      var buffer = [WCHAR](repeating: 0, count: wcharCount)
      let readStatus = valueName.withCString(encodedAs: UTF16.self) { valNamePtr in
        buffer.withUnsafeMutableBytes { bufBytes in
          RegQueryValueExW(
            key,
            valNamePtr,
            nil,
            &type,
            bufBytes.baseAddress?.assumingMemoryBound(to: BYTE.self),
            &byteCount
          )
        }
      }
      guard readStatus == ERROR_SUCCESS else { return nil }
      return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF16.self)
    }

    private static func writeRegisteredValue(_ value: String) throws {
      var hKey: HKEY?
      let openStatus = runKeyPath.withCString(encodedAs: UTF16.self) { subkeyPtr in
        RegOpenKeyExW(HKEY_CURRENT_USER, subkeyPtr, 0, keyWriteAccess, &hKey)
      }
      guard openStatus == ERROR_SUCCESS, let key = hKey else {
        throw WindowsServiceRegistrationError.registryOpenFailed(openStatus)
      }
      defer { RegCloseKey(key) }

      let utf16Data = Array(value.utf16) + [0]
      let setStatus = valueName.withCString(encodedAs: UTF16.self) { valNamePtr in
        utf16Data.withUnsafeBytes { dataBytes in
          RegSetValueExW(
            key,
            valNamePtr,
            0,
            DWORD(REG_SZ),
            dataBytes.baseAddress?.assumingMemoryBound(to: BYTE.self),
            DWORD(dataBytes.count)
          )
        }
      }
      guard setStatus == ERROR_SUCCESS else {
        throw WindowsServiceRegistrationError.registryWriteFailed(setStatus)
      }
    }

    private static func deleteRegisteredValue() throws {
      var hKey: HKEY?
      let openStatus = runKeyPath.withCString(encodedAs: UTF16.self) { subkeyPtr in
        RegOpenKeyExW(HKEY_CURRENT_USER, subkeyPtr, 0, keyWriteAccess, &hKey)
      }
      guard openStatus == ERROR_SUCCESS, let key = hKey else {
        throw WindowsServiceRegistrationError.registryOpenFailed(openStatus)
      }
      defer { RegCloseKey(key) }

      let deleteStatus = valueName.withCString(encodedAs: UTF16.self) { valNamePtr in
        RegDeleteValueW(key, valNamePtr)
      }
      if deleteStatus != ERROR_SUCCESS && deleteStatus != ERROR_FILE_NOT_FOUND {
        throw WindowsServiceRegistrationError.registryDeleteFailed(deleteStatus)
      }
    }
  }
#else
  public struct WindowsServiceRegistration: Sendable {
    public static let runKeyPath = "Software\\Microsoft\\Windows\\CurrentVersion\\Run"
    public static let valueName = "CodexBridgeService"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var inMemoryValue: String?

    public static func isRegistered(executablePath: String? = nil) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard let value = inMemoryValue, !value.isEmpty else { return false }
      if let executablePath {
        return normalizePath(value) == normalizePath(executablePath)
      }
      return true
    }

    public static func register(executablePath: String? = nil) throws {
      guard let path = executablePath ?? serviceExecutablePath(), !path.isEmpty else {
        throw WindowsServiceRegistrationError.executableNotFound
      }
      lock.lock()
      defer { lock.unlock() }
      inMemoryValue = formattedValue(for: path)
    }

    public static func unregister() throws {
      lock.lock()
      defer { lock.unlock() }
      inMemoryValue = nil
    }

    public static func serviceExecutablePath() -> String? {
      "C:\\Program Files\\CodexBridge\\codex-bridge-service.exe"
    }

    public static func startupCommand(for applicationPath: String) -> String {
      "\(formattedValue(for: applicationPath)) --ensure-service"
    }

    public static func resetForTesting() {
      lock.lock()
      defer { lock.unlock() }
      inMemoryValue = nil
    }
  }
#endif

extension WindowsServiceRegistration {
  public static func formattedValue(for executablePath: String) -> String {
    let trimmed = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2 {
      return trimmed
    }
    return "\"\(trimmed)\""
  }

  public static func unquotedPath(from value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2 {
      let start = trimmed.index(after: trimmed.startIndex)
      let end = trimmed.index(before: trimmed.endIndex)
      return String(trimmed[start..<end])
    }
    return trimmed
  }

  public static func normalizePath(_ path: String) -> String {
    unquotedPath(from: path).lowercased()
  }
}

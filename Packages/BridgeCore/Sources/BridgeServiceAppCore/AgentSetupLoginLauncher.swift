import BridgeAgentCore
import BridgeIPC
import Crypto
import Foundation

#if os(Windows)
  import WinSDK
#endif

public enum AgentSetupLoginLauncherError: LocalizedError {
  case invalidCommand
  case terminalUnavailable
  case launchFailed(Int32)
  case insecureDirectory

  public var errorDescription: String? {
    switch self {
    case .invalidCommand: return "登录程序或工作目录无效，请重新检测安装。"
    case .terminalUnavailable: return "没有找到可用终端，请按照登录指引在终端中完成操作。"
    case .launchFailed(let code): return "无法打开登录终端（系统错误 \(code)），请按照登录指引操作。"
    case .insecureDirectory: return "登录脚本目录不安全，请检查应用数据目录权限。"
    }
  }
}

public enum AgentSetupLoginLauncher {
  public static func open(_ command: IPCAgentSetupLoginCommand) throws {
    try validate(command)
    let script = try prepareScript(command)
    try openTerminal(script: script)
  }

  public static func manualCommand(_ command: IPCAgentSetupLoginCommand) throws -> String {
    try validate(command)
    let script = try prepareScript(command)
    #if os(Windows)
      return "powershell.exe -NoProfile -ExecutionPolicy Bypass -File "
        + AgentSetupLoginScript.windowsQuote(script.path)
    #else
      return "/bin/sh " + AgentSetupLoginScript.posixQuote(script.path)
    #endif
  }

  static func validate(_ command: IPCAgentSetupLoginCommand) throws {
    let values =
      [command.executablePath, command.workingDirectory, command.instructions]
      + command.arguments + Array(command.environment.values)
    guard AgentPathSemantics.isAbsolute(command.executablePath),
      AgentPathSemantics.isAbsolute(command.workingDirectory),
      values.allSatisfy({ !$0.contains("\0") }),
      FileManager.default.fileExists(atPath: command.executablePath)
    else { throw AgentSetupLoginLauncherError.invalidCommand }
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: command.workingDirectory, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw AgentSetupLoginLauncherError.invalidCommand }
  }

  static func prepareScript(_ command: IPCAgentSetupLoginCommand, directory: URL? = nil) throws
    -> URL
  {
    let directory = directory ?? scriptDirectory()
    try preparePrivateDirectory(directory)
    #if os(Windows)
      let suffix = "ps1"
      let text = AgentSetupLoginScript.powerShell(command)
      let data = Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
    #else
      #if os(macOS)
        let suffix = "command"
      #else
        let suffix = "sh"
      #endif
      let data = Data(AgentSetupLoginScript.posix(command).utf8)
    #endif
    let url = directory.appendingPathComponent("login-\(scriptIdentifier(command)).\(suffix)")
    if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      attributes[.type] as? FileAttributeType != .typeRegular
    {
      throw AgentSetupLoginLauncherError.insecureDirectory
    }
    try data.write(to: url, options: .atomic)
    #if !os(Windows)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    #endif
    return url
  }

  static func scriptIdentifier(_ command: IPCAgentSetupLoginCommand) -> String {
    let components = [command.executablePath, command.workingDirectory] + command.arguments
    let encoded = components.map { "\($0.utf8.count):\($0)" }.joined()
    return SHA256.hash(data: Data(encoded.utf8)).prefix(12).map { String(format: "%02x", $0) }
      .joined()
  }

  private static func scriptDirectory() -> URL {
    #if os(Linux)
      let configured = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
      let parent =
        configured.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
    #else
      let parent =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first ?? FileManager.default.homeDirectoryForCurrentUser
    #endif
    return parent.appendingPathComponent("CodexBridgeService/AgentSetupLogin", isDirectory: true)
  }

  private static func preparePrivateDirectory(_ directory: URL) throws {
    #if os(Windows)
      let flags = directory.path.withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
      if flags != INVALID_FILE_ATTRIBUTES,
        flags & UInt32(FILE_ATTRIBUTE_REPARSE_POINT) != 0
      {
        throw AgentSetupLoginLauncherError.insecureDirectory
      }
    #endif
    if let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
      attributes[.type] as? FileAttributeType != .typeDirectory
    {
      throw AgentSetupLoginLauncherError.insecureDirectory
    }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    #if !os(Windows)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    #endif
  }
}

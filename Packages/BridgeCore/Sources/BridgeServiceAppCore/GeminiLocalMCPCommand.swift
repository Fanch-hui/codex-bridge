import Foundation

public enum GeminiLocalMCPCommand {
  public static func command(executableURL: URL? = Bundle.main.executableURL) throws -> String {
    guard let executableURL, executableURL.isFileURL else {
      throw CommandError.executableUnavailable
    }
    let path = executableURL.path
    guard !path.isEmpty, !path.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
      throw CommandError.executableUnavailable
    }
    #if os(Windows)
      let quoted = path
    #else
      let quoted = path.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "$", with: "\\$")
        .replacingOccurrences(of: "`", with: "\\`")
    #endif
    return "\"\(quoted)\" --mcp-stdio"
  }

  public enum CommandError: LocalizedError {
    case executableUnavailable

    public var errorDescription: String? {
      "无法确定当前 App 的启动路径，请从安装目录重新打开 Codex Bridge。"
    }
  }
}

import BridgeAgentCore
import Foundation

enum AntigravityCLIPermissionRemediation {
  static func make(
    toolName: String,
    toolArguments: String
  ) -> AgentNativePermissionRemediation? {
    guard toolName.utf8.count <= 256, toolArguments.utf8.count <= 64 * 1_024,
      !toolArguments.contains("\0"), !isRedacted(toolArguments),
      let data = toolArguments.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data),
      let arguments = object as? [String: Any]
    else { return nil }

    let normalizedName = toolName.lowercased()
    let candidate: (action: String, target: String)?
    if normalizedName == "run_command" {
      candidate = command(arguments)
    } else if ["read_url_content", "read_url", "web_read", "web_fetch", "fetch_url"]
      .contains(normalizedName)
    {
      candidate = url(arguments, action: "read_url")
    } else if normalizedName == "browser" || normalizedName.hasPrefix("browser_") {
      candidate = url(arguments, action: "execute_url")
    } else {
      candidate = mcp(toolName: toolName, arguments: arguments)
    }
    guard let candidate,
      (try? AntigravityCLISettingsDocument.validatedRule(
        action: candidate.action,
        target: candidate.target
      )) != nil
    else { return nil }
    let displayRule = "\(candidate.action)(\(candidate.target))"
    return try? AgentNativePermissionRemediation(
      candidateID: AntigravityCLISettingsDocument.digest(Data(displayRule.utf8)),
      action: candidate.action,
      target: candidate.target,
      displayRule: displayRule,
      requiresConfirmation: AntigravityCLISettingsDocument.requiresConfirmation(
        action: candidate.action,
        target: candidate.target
      )
    )
  }

  private static func command(_ arguments: [String: Any]) -> (String, String)? {
    guard let value = uniqueString(arguments, keys: ["command", "CommandLine"]) else {
      return nil
    }
    return ("command", value)
  }

  private static func url(
    _ arguments: [String: Any],
    action: String
  ) -> (String, String)? {
    guard
      let raw = uniqueString(
        arguments,
        keys: ["url", "URL", "targetUrl", "target_url"]
      ),
      !AntigravityCLISettingsDocument.isSensitive(raw),
      let components = URLComponents(string: raw),
      ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
      let host = components.host?.lowercased(), !host.isEmpty
    else { return nil }
    let target = components.port.map { "\(host):\($0)" } ?? host
    return (action, target)
  }

  private static func mcp(
    toolName: String,
    arguments: [String: Any]
  ) -> (String, String)? {
    let components = toolName.components(separatedBy: "__")
    let fromName: (String, String)? =
      components.count == 3 && components[0].lowercased() == "mcp"
      ? (components[1], components[2]) : nil
    let server = uniqueString(arguments, keys: ["server", "serverName", "server_name"])
    let tool = uniqueString(arguments, keys: ["tool", "toolName", "tool_name"])
    let fromArguments = server.flatMap { server in tool.map { (server, $0) } }
    guard let pair = unambiguous(fromName, fromArguments),
      validMCPComponent(pair.0), validMCPComponent(pair.1)
    else { return nil }
    return ("mcp", "\(pair.0)/\(pair.1)")
  }

  private static func uniqueString(
    _ arguments: [String: Any],
    keys: [String]
  ) -> String? {
    let values = Set(
      keys.compactMap { arguments[$0] as? String }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    )
    guard values.count == 1 else { return nil }
    return values.first
  }

  private static func unambiguous(
    _ first: (String, String)?,
    _ second: (String, String)?
  ) -> (String, String)? {
    switch (first, second) {
    case (let first?, nil): first
    case (nil, let second?): second
    case (let first?, let second?) where first == second: first
    default: nil
    }
  }

  private static func validMCPComponent(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256
      && value.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:")).contains($0)
      }
  }

  private static func isRedacted(_ value: String) -> Bool {
    let normalized = value.lowercased()
    return ["<redacted>", "[redacted]", "••••", "***redacted***"]
      .contains(where: normalized.contains)
  }
}

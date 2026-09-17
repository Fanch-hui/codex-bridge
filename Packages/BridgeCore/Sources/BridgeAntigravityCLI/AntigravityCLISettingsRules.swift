import BridgeAgentCore
import Crypto
import Foundation

extension AntigravityCLISettingsDocument {
  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func ruleID(
    effect: AgentNativePermissionEffect,
    occurrence: Int,
    rawRule: String
  ) -> String {
    digest(Data("\(effect.rawValue)\0\(occurrence)\0\(rawRule)".utf8))
  }

  static func validatedRule(action: String, target: String) throws -> String {
    guard actions.contains(action), !target.isEmpty, target.utf8.count <= 4 * 1_024,
      !target.contains("\0"), !target.unicodeScalars.contains(where: { $0.value < 0x20 }),
      !isSensitive(target)
    else {
      throw AgentNativePermissionPolicyError.ruleInvalid
    }
    return "\(action)(\(target))"
  }

  static func parse(_ rawRule: String) -> (action: String, target: String) {
    guard let opening = rawRule.firstIndex(of: "("), rawRule.last == ")",
      opening > rawRule.startIndex
    else {
      return ("unknown", rawRule)
    }
    let action = String(rawRule[..<opening])
    let targetStart = rawRule.index(after: opening)
    let targetEnd = rawRule.index(before: rawRule.endIndex)
    guard !action.isEmpty, targetStart <= targetEnd else { return ("unknown", rawRule) }
    return (action, String(rawRule[targetStart..<targetEnd]))
  }

  static func isSensitive(_ value: String) -> Bool {
    let normalized = value.lowercased()
    let markers = [
      "api_key", "apikey", "api-key", "token", "cookie", "authorization", "bearer ",
      "password", "passwd", "secret", "private_key", "private-key",
    ]
    if markers.contains(where: normalized.contains) { return true }
    guard let components = URLComponents(string: value) else { return false }
    return components.user != nil || components.password != nil
  }

  static func requiresConfirmation(action: String, target: String) -> Bool {
    if action == "unsandboxed" || target.contains("*") { return true }
    if action == "mcp", !target.contains("/") { return true }
    return false
  }

  static func warnings(
    mode: String,
    lists: [AgentNativePermissionEffect: [String]],
    unknownCount: Int
  ) -> [String] {
    var warnings: [String] = []
    if !modes.contains(mode) {
      warnings.append("The current tool permission mode is not recognized by this Bridge version.")
    }
    if unknownCount > 0 {
      warnings.append("Some permission rules use actions not recognized by this Bridge version.")
    }
    if mode == "always-proceed" {
      warnings.append("Always Proceed is enabled for this AGY Global configuration.")
    }
    if lists.values.joined().contains(where: {
      let parsed = parse($0)
      return requiresConfirmation(action: parsed.action, target: parsed.target)
    }) {
      warnings.append("Some existing rules grant broad or unsandboxed access.")
    }
    var effectsByRule: [String: Set<AgentNativePermissionEffect>] = [:]
    for (effect, rules) in lists {
      for rule in rules { effectsByRule[rule, default: []].insert(effect) }
    }
    if effectsByRule.values.contains(where: { $0.count > 1 }) {
      warnings.append("Some rules overlap; Deny takes precedence over Ask, then Allow.")
    }
    return warnings
  }

  static func modeDisplayName(_ mode: String) -> String {
    switch mode {
    case "request-review": "Request Review"
    case "proceed-in-sandbox": "Proceed in Sandbox"
    case "strict": "Strict"
    case "always-proceed": "Always Proceed"
    default: mode
    }
  }
}

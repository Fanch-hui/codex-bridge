import BridgeAgentCore
import CryptoKit
import Foundation

struct AntigravityCLISettingsDocument {
  static let defaultToolPermission = "request-review"
  static let modes = [
    "request-review", "proceed-in-sandbox", "strict", "always-proceed",
  ]
  static let actions = [
    "command", "read_url", "execute_url", "mcp", "read_file", "write_file", "unsandboxed",
  ]
  static let maximumBytes = 512 * 1_024
  static let maximumRulesPerEffect = 512

  private(set) var root: [String: Any]
  let revision: String?

  init(data: Data?) throws {
    guard let data else {
      root = [:]
      revision = nil
      return
    }
    guard !data.isEmpty, data.count <= Self.maximumBytes,
      let object = try? JSONSerialization.jsonObject(with: data),
      let root = object as? [String: Any]
    else {
      throw AgentNativePermissionPolicyError.settingsInvalid
    }
    self.root = root
    revision = Self.digest(data)
    _ = try toolPermission()
    _ = try ruleLists()
  }

  func snapshot(
    providerID: AgentProviderID,
    installationID: AgentInstallationID
  ) throws -> AgentNativePermissionPolicySnapshot {
    let mode = try toolPermission()
    let lists = try ruleLists()
    var rules: [AgentNativePermissionRuleSnapshot] = []
    var unknownCount = 0
    for effect in AgentNativePermissionEffect.allCases {
      for (index, rawRule) in lists[effect, default: []].enumerated() {
        let parsed = Self.parse(rawRule)
        let occurrence = lists[effect, default: []][..<index].filter { $0 == rawRule }.count
        let known = Self.actions.contains(parsed.action)
        if !known { unknownCount += 1 }
        let redacted = Self.isSensitive(rawRule)
        let target = redacted ? "••••••" : parsed.target
        rules.append(
          try AgentNativePermissionRuleSnapshot(
            id: Self.ruleID(effect: effect, occurrence: occurrence, rawRule: rawRule),
            effect: effect,
            action: known ? parsed.action : "unknown",
            target: target,
            isEditable: known && !redacted,
            isRedacted: redacted,
            requiresConfirmation: Self.requiresConfirmation(
              action: parsed.action,
              target: parsed.target
            )
          )
        )
      }
    }
    let modes = try Self.modes.map {
      try AgentNativePermissionModeDescriptor(
        id: $0,
        displayName: Self.modeDisplayName($0),
        requiresConfirmation: $0 == "always-proceed"
      )
    }
    return try AgentNativePermissionPolicySnapshot(
      providerID: providerID,
      installationID: installationID,
      toolPermission: mode,
      availableModes: modes,
      availableActions: Self.actions,
      rules: rules,
      revision: revision,
      warnings: Self.warnings(mode: mode, lists: lists, unknownCount: unknownCount)
    )
  }

  mutating func apply(_ mutation: AgentNativePermissionMutation) throws {
    switch mutation {
    case .setToolPermission(let mode):
      guard Self.modes.contains(mode) else {
        throw AgentNativePermissionPolicyError.ruleInvalid
      }
      root["toolPermission"] = mode
    case .addRule(let effect, let action, let target):
      let rawRule = try Self.validatedRule(action: action, target: target)
      var lists = try ruleLists()
      guard !lists.values.joined().contains(rawRule) else {
        throw AgentNativePermissionPolicyError.ruleInvalid
      }
      lists[effect, default: []].append(rawRule)
      try writeRuleLists(lists)
    case .replaceRule(let id, let effect, let action, let target):
      let rawRule = try Self.validatedRule(action: action, target: target)
      var lists = try ruleLists()
      let old = try locateRule(id: id, lists: lists)
      guard !Self.isSensitive(old.rawRule), Self.actions.contains(Self.parse(old.rawRule).action)
      else {
        throw AgentNativePermissionPolicyError.ruleInvalid
      }
      lists[old.effect]?.remove(at: old.index)
      guard !lists.values.joined().contains(rawRule) else {
        throw AgentNativePermissionPolicyError.ruleInvalid
      }
      lists[effect, default: []].append(rawRule)
      try writeRuleLists(lists)
    case .removeRule(let id):
      var lists = try ruleLists()
      let old = try locateRule(id: id, lists: lists)
      lists[old.effect]?.remove(at: old.index)
      try writeRuleLists(lists)
    }
  }

  func encoded() throws -> Data {
    guard JSONSerialization.isValidJSONObject(root),
      let data = try? JSONSerialization.data(
        withJSONObject: root,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      ),
      data.count < Self.maximumBytes
    else {
      throw AgentNativePermissionPolicyError.settingsInvalid
    }
    return data + Data([0x0A])
  }

  private func toolPermission() throws -> String {
    guard let value = root["toolPermission"] else { return Self.defaultToolPermission }
    guard let value = value as? String, !value.isEmpty, value.utf8.count <= 128,
      !value.contains("\0")
    else {
      throw AgentNativePermissionPolicyError.settingsInvalid
    }
    return value
  }

  private func ruleLists() throws -> [AgentNativePermissionEffect: [String]] {
    guard let value = root["permissions"] else { return [:] }
    guard let permissions = value as? [String: Any] else {
      throw AgentNativePermissionPolicyError.settingsInvalid
    }
    var result: [AgentNativePermissionEffect: [String]] = [:]
    for effect in AgentNativePermissionEffect.allCases {
      guard let raw = permissions[effect.rawValue] else { continue }
      guard let values = raw as? [Any], values.count <= Self.maximumRulesPerEffect else {
        throw AgentNativePermissionPolicyError.settingsInvalid
      }
      var strings: [String] = []
      for value in values {
        guard let string = value as? String, !string.isEmpty,
          string.utf8.count <= 4 * 1_024, !string.contains("\0")
        else {
          throw AgentNativePermissionPolicyError.settingsInvalid
        }
        strings.append(string)
      }
      result[effect] = strings
    }
    return result
  }

  private mutating func writeRuleLists(
    _ lists: [AgentNativePermissionEffect: [String]]
  ) throws {
    var permissions = (root["permissions"] as? [String: Any]) ?? [:]
    for effect in AgentNativePermissionEffect.allCases {
      let values = lists[effect, default: []]
      guard values.count <= Self.maximumRulesPerEffect else {
        throw AgentNativePermissionPolicyError.ruleInvalid
      }
      permissions[effect.rawValue] = values
    }
    root["permissions"] = permissions
  }

  private func locateRule(
    id: String,
    lists: [AgentNativePermissionEffect: [String]]
  ) throws -> (effect: AgentNativePermissionEffect, index: Int, rawRule: String) {
    for effect in AgentNativePermissionEffect.allCases {
      for (index, rawRule) in lists[effect, default: []].enumerated()
      where Self.ruleID(
        effect: effect,
        occurrence: lists[effect, default: []][..<index].filter { $0 == rawRule }.count,
        rawRule: rawRule
      ) == id {
        return (effect, index, rawRule)
      }
    }
    throw AgentNativePermissionPolicyError.ruleInvalid
  }
}

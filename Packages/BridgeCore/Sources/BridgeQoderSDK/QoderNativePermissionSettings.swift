import BridgeAgentCore
import BridgeSecurity
import Foundation

struct QoderNativePermissionSettingsStore: Sendable {
  static let maximumBytes = 512 * 1_024
  private let resolver: ProjectPathResolver
  private let filePath: SecureRelativePath

  init(directory: String) throws {
    guard AgentPathSemantics.isAbsolute(directory), !directory.contains("\0") else {
      throw AgentNativePermissionPolicyError.settingsUnsafe
    }
    #if os(Windows)
      let attributes: [FileAttributeKey: Any]? = nil
    #else
      let attributes: [FileAttributeKey: Any]? = [.posixPermissions: 0o700]
    #endif
    do {
      try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true,
        attributes: attributes
      )
      resolver = ProjectPathResolver(
        root: try RegisteredRoot(capturing: URL(fileURLWithPath: directory, isDirectory: true))
      )
      filePath = try SecureRelativePath("settings.json")
    } catch {
      throw AgentNativePermissionPolicyError.settingsUnsafe
    }
  }

  func load() throws -> (
    document: QoderNativePermissionSettingsDocument, revision: SecureFileRevision?
  ) {
    do {
      let writer = SecureProjectFileWriter(maximumBytes: Self.maximumBytes)
      let revision = try writer.revision(relativePath: filePath, through: resolver)
      guard revision != nil else { return (QoderNativePermissionSettingsDocument(), nil) }
      let file = try SecureFileReader(maximumBytes: Self.maximumBytes, maximumLines: 16_384)
        .read(filePath, through: resolver)
      return (try QoderNativePermissionSettingsDocument(data: Data(file.text.utf8)), revision)
    } catch let error as AgentNativePermissionPolicyError {
      throw error
    } catch {
      throw Self.mappedError(error)
    }
  }

  func save(
    _ document: QoderNativePermissionSettingsDocument,
    expectedRevision: SecureFileRevision?
  ) throws -> SecureFileRevision {
    do {
      let result = try SecureProjectFileWriter(maximumBytes: Self.maximumBytes).write(
        relativePath: filePath,
        through: resolver,
        mode: expectedRevision == nil ? .create : .replace,
        content: try document.encoded(),
        expectedSHA256: expectedRevision?.sha256,
        createParents: false
      )
      return result.newRevision
    } catch let error as AgentNativePermissionPolicyError {
      throw error
    } catch {
      throw Self.mappedError(error)
    }
  }

  private static func mappedError(_ error: any Error) -> AgentNativePermissionPolicyError {
    if let pathError = error as? PathSecurityError, pathError == .revisionConflict {
      return .revisionConflict
    }
    return .settingsUnsafe
  }
}

struct QoderNativePermissionSettingsDocument {
  private static let modes = [
    "default", "accept_edits", "plan", "auto", "bypass_permissions", "dont_ask",
  ]
  private static let effects: [(AgentNativePermissionEffect, String)] = [
    (.allow, "allow"), (.ask, "ask"), (.deny, "deny"),
  ]
  private static let availableActions = [
    "Read", "Edit", "Write", "NotebookEdit", "Bash", "Grep", "Glob", "WebFetch",
    "WebSearch", "Agent", "MCP", "*",
  ]
  private static let maximumRulesPerEffect = 512

  private var root: [String: Any]

  init() {
    root = [:]
  }

  init(data: Data) throws {
    guard !data.isEmpty, data.count <= QoderNativePermissionSettingsStore.maximumBytes,
      let object = try? JSONSerialization.jsonObject(with: data),
      let root = object as? [String: Any]
    else { throw AgentNativePermissionPolicyError.settingsInvalid }
    self.root = root
    _ = try permissionMode()
    _ = try ruleLists()
  }

  func snapshot(
    installation: AgentInstallation,
    distribution: QoderDistribution,
    revision: String?
  ) throws -> AgentNativePermissionPolicySnapshot {
    let currentMode = try permissionMode()
    let rules = try ruleSnapshots()
    var modes = try Self.modes.map { try Self.modeDescriptor($0) }
    if !modes.contains(where: { $0.id == currentMode }) {
      modes.append(
        try AgentNativePermissionModeDescriptor(
          id: currentMode,
          displayName: "未知的 Qoder 权限模式（\(currentMode)）",
          requiresConfirmation: true
        ))
    }
    return try AgentNativePermissionPolicySnapshot(
      providerID: .qoder,
      installationID: installation.id,
      toolPermission: currentMode,
      availableModes: modes,
      availableActions: Self.availableActions,
      rules: rules,
      revision: revision,
      warnings: [
        "规则保存在 \(distribution == .cn ? "Qoder CN" : "Qoder") 用户级 settings.json，会影响该地区使用同一配置目录的 Qoder CLI 任务。Bridge 的任务只读上限仍由服务端和宿主执行。"
      ]
    )
  }

  mutating func apply(_ mutation: AgentNativePermissionMutation) throws {
    switch mutation {
    case .setToolPermission(let value):
      guard Self.modes.contains(value) else { throw AgentNativePermissionPolicyError.ruleInvalid }
      var general = try generalSettings()
      general["defaultPermissionMode"] = value
      root["general"] = general
    case .addRule(let effect, let action, let target):
      let raw = try Self.nativeRule(action: action, target: target)
      var lists = try ruleLists()
      guard !lists[effect, default: []].contains(raw),
        lists[effect, default: []].count < Self.maximumRulesPerEffect
      else { throw AgentNativePermissionPolicyError.ruleInvalid }
      lists[effect, default: []].append(raw)
      try writeRuleLists(lists)
    case .replaceRule(let id, let effect, let action, let target):
      let raw = try Self.nativeRule(action: action, target: target)
      var lists = try ruleLists()
      let old = try locateRule(id: id, lists: lists)
      guard old.isEditable, !lists[effect, default: []].contains(raw) else {
        throw AgentNativePermissionPolicyError.ruleInvalid
      }
      lists[old.effect]?.remove(at: old.index)
      guard lists[effect, default: []].count < Self.maximumRulesPerEffect else {
        throw AgentNativePermissionPolicyError.ruleInvalid
      }
      lists[effect, default: []].append(raw)
      try writeRuleLists(lists)
    case .removeRule(let id):
      var lists = try ruleLists()
      let old = try locateRule(id: id, lists: lists)
      guard old.isEditable else { throw AgentNativePermissionPolicyError.ruleInvalid }
      lists[old.effect]?.remove(at: old.index)
      try writeRuleLists(lists)
    }
  }

  func encoded() throws -> Data {
    guard JSONSerialization.isValidJSONObject(root),
      let data = try? JSONSerialization.data(
        withJSONObject: root,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      ), data.count <= QoderNativePermissionSettingsStore.maximumBytes
    else { throw AgentNativePermissionPolicyError.settingsInvalid }
    return data + Data([0x0A])
  }

  private func permissionMode() throws -> String {
    let general = try generalSettings()
    guard let raw = general["defaultPermissionMode"] else { return "default" }
    guard let value = raw as? String, !value.isEmpty, value.utf8.count <= 128,
      !value.contains("\0")
    else { throw AgentNativePermissionPolicyError.settingsInvalid }
    let normalized = value.lowercased()
    let aliases = [
      "acceptedits": "accept_edits", "bypasspermissions": "bypass_permissions",
      "yolo": "bypass_permissions", "dontask": "dont_ask",
    ]
    let result = aliases[normalized] ?? normalized
    guard
      result.utf8.allSatisfy({
        (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
      })
    else { throw AgentNativePermissionPolicyError.settingsInvalid }
    return result
  }

  private func generalSettings() throws -> [String: Any] {
    guard let value = root["general"] else { return [:] }
    guard let general = value as? [String: Any] else {
      throw AgentNativePermissionPolicyError.settingsInvalid
    }
    return general
  }

  private func ruleLists() throws -> [AgentNativePermissionEffect: [String]] {
    guard let value = root["permissions"] else { return [:] }
    guard let permissions = value as? [String: Any] else {
      throw AgentNativePermissionPolicyError.settingsInvalid
    }
    var result: [AgentNativePermissionEffect: [String]] = [:]
    for (effect, key) in Self.effects {
      guard let raw = permissions[key] else { continue }
      guard let values = raw as? [Any], values.count <= Self.maximumRulesPerEffect else {
        throw AgentNativePermissionPolicyError.settingsInvalid
      }
      var strings: [String] = []
      for item in values {
        guard let string = item as? String, !string.isEmpty,
          string.utf8.count <= 4 * 1_024, !string.contains("\0")
        else { throw AgentNativePermissionPolicyError.settingsInvalid }
        strings.append(string)
      }
      result[effect] = strings
    }
    return result
  }

  private func ruleSnapshots() throws -> [AgentNativePermissionRuleSnapshot] {
    let lists = try ruleLists()
    var result: [AgentNativePermissionRuleSnapshot] = []
    for effect in AgentNativePermissionEffect.allCases {
      for (index, raw) in lists[effect, default: []].enumerated() {
        let occurrence = lists[effect, default: []][..<index].filter { $0 == raw }.count
        let parsed = Self.parse(raw)
        let sensitive = Self.isSensitive(raw)
        let known = Self.isEditableAction(parsed.action)
        result.append(
          try AgentNativePermissionRuleSnapshot(
            id: Self.ruleID(effect: effect, occurrence: occurrence, raw: raw),
            effect: effect,
            action: known ? parsed.action : "unknown",
            target: sensitive ? "••••••" : parsed.target,
            isEditable: known && !sensitive,
            isRedacted: sensitive,
            requiresConfirmation: Self.requiresConfirmation(
              effect: effect, action: parsed.action, target: parsed.target)
          ))
      }
    }
    return result
  }

  private func locateRule(
    id: String,
    lists: [AgentNativePermissionEffect: [String]]
  ) throws -> (effect: AgentNativePermissionEffect, index: Int, raw: String, isEditable: Bool) {
    for effect in AgentNativePermissionEffect.allCases {
      for (index, raw) in lists[effect, default: []].enumerated() {
        let occurrence = lists[effect, default: []][..<index].filter { $0 == raw }.count
        guard Self.ruleID(effect: effect, occurrence: occurrence, raw: raw) == id else { continue }
        let parsed = Self.parse(raw)
        return (effect, index, raw, Self.isEditableAction(parsed.action) && !Self.isSensitive(raw))
      }
    }
    throw AgentNativePermissionPolicyError.ruleInvalid
  }

  private mutating func writeRuleLists(_ lists: [AgentNativePermissionEffect: [String]]) throws {
    var permissions = (root["permissions"] as? [String: Any]) ?? [:]
    for (effect, key) in Self.effects { permissions[key] = lists[effect, default: []] }
    root["permissions"] = permissions
  }

  private static func nativeRule(action: String, target: String) throws -> String {
    guard availableActions.contains(action), !target.isEmpty, target.utf8.count <= 4 * 1_024,
      !target.contains("\0"), !target.contains("\n"), !target.contains("\r")
    else { throw AgentNativePermissionPolicyError.ruleInvalid }
    if action == "MCP" {
      let components = target.components(separatedBy: "__")
      guard components.count >= 3, components[0] == "mcp",
        !components[1].isEmpty, !components[2].isEmpty
      else {
        throw AgentNativePermissionPolicyError.ruleInvalid
      }
      return target
    }
    if action == "*" {
      guard target == "*" else { throw AgentNativePermissionPolicyError.ruleInvalid }
      return "*"
    }
    guard target != "*" else { return action }
    let escaped = target.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "(", with: "\\(")
      .replacingOccurrences(of: ")", with: "\\)")
    return "\(action)(\(escaped))"
  }

  private static func parse(_ raw: String) -> (action: String, target: String) {
    if raw.hasPrefix("mcp__") { return ("MCP", raw) }
    guard let opening = raw.firstIndex(of: "("), raw.last == ")" else {
      return (raw, "*")
    }
    return (
      String(raw[..<opening]),
      String(raw[raw.index(after: opening)..<raw.index(before: raw.endIndex)])
        .replacingOccurrences(of: "\\)", with: ")")
        .replacingOccurrences(of: "\\(", with: "(")
        .replacingOccurrences(of: "\\\\", with: "\\")
    )
  }

  private static func isEditableAction(_ action: String) -> Bool {
    availableActions.contains(action)
      || action.hasPrefix("mcp__") && action.split(separator: "_").count >= 4
  }

  private static func isSensitive(_ value: String) -> Bool {
    let normalized = value.lowercased()
    return ["api_key", "apikey", "token", "password", "authorization", "secret="]
      .contains(where: normalized.contains)
  }

  private static func requiresConfirmation(
    effect: AgentNativePermissionEffect,
    action: String,
    target: String
  ) -> Bool {
    effect == .allow
      && (action == "*" || action == "Bash" || action == "MCP" || target.contains("*"))
  }

  private static func ruleID(
    effect: AgentNativePermissionEffect,
    occurrence: Int,
    raw: String
  ) -> String {
    let value = [effect.rawValue, String(occurrence), raw].joined(separator: "\u{0}")
    return "qoder-rule-" + String(SecureFileRevision.digest(of: Data(value.utf8)).sha256.prefix(40))
  }

  private static func modeDescriptor(_ value: String) throws -> AgentNativePermissionModeDescriptor
  {
    let names = [
      "default": "标准权限", "accept_edits": "自动接受编辑", "plan": "计划模式",
      "auto": "自动权限", "bypass_permissions": "跳过权限检查", "dont_ask": "不询问并拒绝未授权操作",
    ]
    return try AgentNativePermissionModeDescriptor(
      id: value,
      displayName: names[value] ?? value,
      requiresConfirmation: ["accept_edits", "auto", "bypass_permissions"].contains(value)
    )
  }
}

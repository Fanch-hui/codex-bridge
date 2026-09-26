import BridgeAgentCore
import BridgeSecurity
import Foundation

public actor PiNativePermissionPolicyManager: AgentNativePermissionPolicyManaging {
  private static let mode = "bridge-managed"
  private static let actions = [
    "read", "grep", "find", "ls", "write", "edit", "bash", "powershell",
  ]
  private let baseDirectory: String

  public init(runtimeBaseDirectory: String) {
    baseDirectory = runtimeBaseDirectory
  }

  public func snapshot(
    installation: AgentInstallation
  ) async throws -> AgentNativePermissionPolicySnapshot {
    try validate(installation)
    let store = try PiNativePermissionPolicyStore(
      baseDirectory: baseDirectory,
      installationID: installation.id.rawValue
    )
    let loaded = try store.load(installationID: installation.id.rawValue)
    return try Self.snapshot(
      installation: installation,
      document: loaded.document,
      revision: loaded.revision?.sha256
    )
  }

  public func update(
    installation: AgentInstallation,
    mutation: AgentNativePermissionMutation,
    expectedRevision: String?
  ) async throws -> AgentNativePermissionPolicySnapshot {
    try validate(installation)
    let store = try PiNativePermissionPolicyStore(
      baseDirectory: baseDirectory,
      installationID: installation.id.rawValue
    )
    let loaded = try store.load(installationID: installation.id.rawValue)
    guard loaded.revision?.sha256 == expectedRevision else {
      throw AgentNativePermissionPolicyError.revisionConflict
    }
    var document = loaded.document
    try apply(mutation, to: &document)
    let revision = try store.save(document, expectedRevision: loaded.revision)
    return try Self.snapshot(
      installation: installation,
      document: document,
      revision: revision.sha256
    )
  }

  public func remediation(
    toolName _: String,
    toolArguments _: String
  ) async -> AgentNativePermissionRemediation? {
    nil
  }

  private func validate(_ installation: AgentInstallation) throws {
    guard installation.providerID == .pi else {
      throw AgentNativePermissionPolicyError.unavailable
    }
  }

  private func apply(
    _ mutation: AgentNativePermissionMutation,
    to document: inout PiNativePermissionPolicyDocument
  ) throws {
    switch mutation {
    case .setToolPermission(let mode):
      guard mode == Self.mode else { throw AgentNativePermissionPolicyError.ruleInvalid }
    case .addRule(let effect, let action, let target):
      let rule = try PiNativePermissionRule(effect: effect, action: action, target: target)
      guard
        !document.rules.contains(where: {
          $0.effect == effect && $0.action == action && $0.target == target
        })
      else { throw AgentNativePermissionPolicyError.ruleInvalid }
      document.rules.append(rule)
    case .replaceRule(let id, let effect, let action, let target):
      let rule = try PiNativePermissionRule(effect: effect, action: action, target: target)
      guard let index = document.rules.firstIndex(where: { $0.id == id }),
        !document.rules.enumerated().contains(where: {
          $0.offset != index && $0.element.effect == effect && $0.element.action == action
            && $0.element.target == target
        })
      else { throw AgentNativePermissionPolicyError.ruleInvalid }
      document.rules[index] = rule
    case .removeRule(let id):
      guard let index = document.rules.firstIndex(where: { $0.id == id }) else {
        throw AgentNativePermissionPolicyError.ruleInvalid
      }
      document.rules.remove(at: index)
    }
    guard document.rules.count <= 1_536 else {
      throw AgentNativePermissionPolicyError.ruleInvalid
    }
  }

  private static func snapshot(
    installation: AgentInstallation,
    document: PiNativePermissionPolicyDocument,
    revision: String?
  ) throws -> AgentNativePermissionPolicySnapshot {
    try AgentNativePermissionPolicySnapshot(
      providerID: .pi,
      installationID: installation.id,
      toolPermission: mode,
      availableModes: [
        try AgentNativePermissionModeDescriptor(
          id: mode,
          displayName: "Bridge 管理（受任务权限限制）"
        )
      ],
      availableActions: actions,
      rules: try document.rules
        .sorted {
          ($0.action, $0.target, $0.effect.rawValue) < ($1.action, $1.target, $1.effect.rawValue)
        }
        .map {
          try AgentNativePermissionRuleSnapshot(
            id: $0.id,
            effect: $0.effect,
            action: $0.action,
            target: $0.target,
            isEditable: true,
            isRedacted: false,
            requiresConfirmation: $0.requiresConfirmation
          )
        },
      revision: revision,
      warnings: [
        "Pi 没有可由 Bridge 管理的原生持久权限文件；这些规则保存在 Bridge 服务数据中。规则不能提高单个任务的只读上限。"
      ]
    )
  }
}

private struct PiNativePermissionRule: Codable, Equatable, Sendable {
  let effect: AgentNativePermissionEffect
  let action: String
  let target: String

  var id: String {
    let value = [effect.rawValue, action, target].joined(separator: "\u{0}")
    return "pi-rule-" + String(SecureFileRevision.digest(of: Data(value.utf8)).sha256.prefix(40))
  }

  var requiresConfirmation: Bool {
    effect == .allow && (target.contains("*") || action == "bash" || action == "powershell")
  }

  init(effect: AgentNativePermissionEffect, action: String, target: String) throws {
    guard Self.actions.contains(action), !target.isEmpty, target.utf8.count <= 4 * 1_024,
      !target.contains("\0"), !target.contains("\n"), !target.contains("\r")
    else { throw AgentNativePermissionPolicyError.ruleInvalid }
    self.effect = effect
    self.action = action
    self.target = target
  }

  private static let actions: Set<String> = [
    "read", "grep", "find", "ls", "write", "edit", "bash", "powershell",
  ]
}

private struct PiNativePermissionPolicyDocument: Codable, Equatable, Sendable {
  let revision: Int
  let installationID: String
  var rules: [PiNativePermissionRule]

  init(installationID: String) {
    revision = 1
    self.installationID = installationID
    rules = []
  }
}

private struct PiNativePermissionPolicyStore: Sendable {
  private let resolver: ProjectPathResolver
  private let filePath: SecureRelativePath

  init(baseDirectory: String, installationID: String) throws {
    do {
      let root = try RegisteredRoot(capturing: URL(fileURLWithPath: baseDirectory))
      resolver = ProjectPathResolver(root: root)
      let key = SecureFileRevision.digest(of: Data(installationID.utf8)).sha256
      let directory = "native-permissions/pi"
      for path in ["native-permissions", directory] {
        let relative = try SecureRelativePath(path)
        if !FileManager.default.fileExists(
          atPath: URL(fileURLWithPath: root.canonicalPath)
            .appendingPathComponent(path, isDirectory: true).path)
        {
          _ = try SecureProjectDirectoryMutation().apply(
            action: .createDirectory,
            relativePath: relative,
            destinationRelativePath: nil,
            through: resolver
          )
        }
        _ = try resolver.resolve(relative)
      }
      filePath = try SecureRelativePath(directory + "/" + key + ".json")
    } catch {
      throw AgentNativePermissionPolicyError.settingsUnsafe
    }
  }

  func load(installationID: String) throws -> (
    document: PiNativePermissionPolicyDocument, revision: SecureFileRevision?
  ) {
    let revision: SecureFileRevision?
    let text: SecureTextFile?
    do {
      revision = try SecureProjectFileWriter(maximumBytes: 512 * 1_024)
        .revision(relativePath: filePath, through: resolver)
      text = try revision.map { _ in
        try SecureFileReader(maximumBytes: 512 * 1_024, maximumLines: 16_384)
          .read(filePath, through: resolver)
      }
    } catch {
      throw Self.mappedError(error)
    }
    guard let revision, let text else {
      return (PiNativePermissionPolicyDocument(installationID: installationID), nil)
    }
    guard
      let document = try? JSONDecoder().decode(
        PiNativePermissionPolicyDocument.self,
        from: Data(text.text.utf8)
      )
    else { throw AgentNativePermissionPolicyError.settingsInvalid }
    guard document.revision == 1, document.installationID == installationID,
      document.rules.count <= 1_536,
      Set(document.rules.map(\.id)).count == document.rules.count
    else { throw AgentNativePermissionPolicyError.settingsInvalid }
    return (document, revision)
  }

  func save(
    _ document: PiNativePermissionPolicyDocument,
    expectedRevision: SecureFileRevision?
  ) throws -> SecureFileRevision {
    do {
      let data = try JSONEncoder().encode(document)
      let result = try SecureProjectFileWriter(maximumBytes: 512 * 1_024).write(
        relativePath: filePath,
        through: resolver,
        mode: expectedRevision == nil ? .create : .replace,
        content: data,
        expectedSHA256: expectedRevision?.sha256,
        createParents: false
      )
      return result.newRevision
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

import BridgeAgentCore
import BridgeMCP
import BridgeServiceCore
import Foundation

struct ServiceAgentDefaultSettings: Sendable {
  let modelKey: ServiceSettingKey
  let effortKey: ServiceSettingKey
  let permissionKey: ServiceSettingKey
  let writeMode: String
  let readMode: String
  let acceptsPermissionAliases: Bool
  let requiresKnownModel: Bool

  static func descriptor(for provider: AgentProviderID, distribution: QoderDistribution? = nil)
    throws -> Self
  {
    if provider == .qoder {
      guard let distribution else { throw BridgeMCPQueryError.contractRejected }
      return distribution == .cn ? qoderCN : qoderInternational
    }
    guard let value = all[provider] else { throw BridgeMCPQueryError.contractRejected }
    return value
  }

  func permissionMode(from settings: ServiceSettings) async throws -> String {
    let value = try await settings.string(for: permissionKey) ?? writeMode
    guard value == writeMode || value == readMode else { throw ServiceStoreError.corruptRecord }
    return value
  }

  func normalizedPermission(_ value: String) throws -> String {
    if value == writeMode || value == readMode { return value }
    guard acceptsPermissionAliases else {
      throw ServiceStoreError.invalidArgument(permissionKey.rawValue)
    }
    switch value {
    case "build", "workspace-write": return writeMode
    case "plan", "read-only": return readMode
    default: throw BridgeMCPQueryError.contractRejected
    }
  }

  private static let all: [AgentProviderID: Self] = [
    .openCode: Self(
      modelKey: .openCodeDefaultModel, effortKey: .openCodeDefaultEffort,
      permissionKey: .openCodeDefaultPermissionMode, writeMode: "build", readMode: "plan",
      acceptsPermissionAliases: false, requiresKnownModel: false),
    .deepSeekHarness: Self(
      modelKey: .deepSeekHarnessDefaultModel, effortKey: .deepSeekHarnessDefaultEffort,
      permissionKey: .deepSeekHarnessDefaultPermissionMode, writeMode: "workspace-write",
      readMode: "read-only",
      acceptsPermissionAliases: true, requiresKnownModel: true),
    .antigravity: Self(
      modelKey: .antigravityDefaultModel, effortKey: .antigravityDefaultEffort,
      permissionKey: .antigravityDefaultPermissionMode, writeMode: "workspace-write",
      readMode: "read-only",
      acceptsPermissionAliases: true, requiresKnownModel: false),
    .pi: Self(
      modelKey: .piDefaultModel, effortKey: .piDefaultEffort,
      permissionKey: .piDefaultPermissionMode, writeMode: "workspace-write", readMode: "read-only",
      acceptsPermissionAliases: true, requiresKnownModel: true),
  ]

  private static let qoderCN = Self(
    modelKey: .qoderCNDefaultModel, effortKey: .qoderCNDefaultEffort,
    permissionKey: .qoderCNDefaultPermissionMode, writeMode: "workspace-write",
    readMode: "read-only",
    acceptsPermissionAliases: true, requiresKnownModel: true)

  private static let qoderInternational = Self(
    modelKey: .qoderInternationalDefaultModel, effortKey: .qoderInternationalDefaultEffort,
    permissionKey: .qoderInternationalDefaultPermissionMode, writeMode: "workspace-write",
    readMode: "read-only",
    acceptsPermissionAliases: true, requiresKnownModel: true)
}

import BridgeAgentCore
import BridgeMCP
import BridgeServiceCore
import Foundation

struct ServiceAgentDefaultSettings: Sendable {
  let modelKey: ServiceSettingKey
  let effortKey: ServiceSettingKey
  let permissionKey: ServiceSettingKey
  let requiresKnownModel: Bool

  static func descriptor(
    for provider: AgentProviderID, distribution: QoderDistribution? = nil,
    connectionMode: DeepSeekHarnessConnectionMode = .acp
  )
    throws -> Self
  {
    if provider == .deepSeekHarnessDesktop
      || (provider == .deepSeekHarness && connectionMode == .nativeDesktop)
    {
      return Self(
        modelKey: .deepSeekHarnessDesktopDefaultModel,
        effortKey: .deepSeekHarnessDesktopDefaultEffort,
        permissionKey: .deepSeekHarnessDesktopDefaultPermissionMode, requiresKnownModel: true)
    }
    if provider == .qoder {
      guard let distribution else { throw BridgeMCPQueryError.contractRejected }
      return distribution == .cn ? qoderCN : qoderInternational
    }
    guard let value = all[provider] else { throw BridgeMCPQueryError.contractRejected }
    return value
  }

  static func requiresKnownModel(for provider: AgentProviderID) throws -> Bool {
    if provider == .qoder { return qoderInternational.requiresKnownModel }
    return try descriptor(for: provider).requiresKnownModel
  }

  func permissionMode(from settings: ServiceSettings) async throws -> String {
    let value = try await settings.string(for: permissionKey) ?? ServicePermissionMode.full.rawValue
    do {
      return try normalizedPermission(value)
    } catch {
      throw ServiceStoreError.corruptRecord
    }
  }

  func normalizedPermission(_ value: String) throws -> String {
    switch value {
    case "build", "workspace-write", "full": return ServicePermissionMode.full.rawValue
    case "plan", "read-only": return ServicePermissionMode.readOnly.rawValue
    default: throw BridgeMCPQueryError.contractRejected
    }
  }

  private static let all: [AgentProviderID: Self] = [
    .openCode: Self(
      modelKey: .openCodeDefaultModel, effortKey: .openCodeDefaultEffort,
      permissionKey: .openCodeDefaultPermissionMode, requiresKnownModel: false),
    .deepSeekHarness: Self(
      modelKey: .deepSeekHarnessDefaultModel, effortKey: .deepSeekHarnessDefaultEffort,
      permissionKey: .deepSeekHarnessDefaultPermissionMode, requiresKnownModel: true),
    .antigravity: Self(
      modelKey: .antigravityDefaultModel, effortKey: .antigravityDefaultEffort,
      permissionKey: .antigravityDefaultPermissionMode, requiresKnownModel: false),
    .pi: Self(
      modelKey: .piDefaultModel, effortKey: .piDefaultEffort,
      permissionKey: .piDefaultPermissionMode, requiresKnownModel: true),
  ]

  private static let qoderCN = Self(
    modelKey: .qoderCNDefaultModel, effortKey: .qoderCNDefaultEffort,
    permissionKey: .qoderCNDefaultPermissionMode, requiresKnownModel: true)

  private static let qoderInternational = Self(
    modelKey: .qoderInternationalDefaultModel, effortKey: .qoderInternationalDefaultEffort,
    permissionKey: .qoderInternationalDefaultPermissionMode, requiresKnownModel: true)
}

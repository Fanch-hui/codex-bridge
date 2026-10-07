import BridgeAgentCore
import BridgeServiceCore
import Crypto
import Foundation

enum ServiceDeepSeekDesktopMigration {
  static func prepare(store: SimpleServiceStore, settings: ServiceSettings) async throws
    -> [String: String]
  {
    let legacy = try await store.agentInstallations(providerID: .deepSeekHarness)
    var desktop = try await store.agentInstallations(providerID: .deepSeekHarnessDesktop)
    var namespaces = try await settings.deepSeekHarnessDesktopNamespaces()
    let oldActive = try await settings.string(for: .deepSeekHarnessDesktopActiveInstallationID)
    var active = oldActive
    for source in legacy where source.runtimeArtifacts.contains(where: { $0.role == .archive }) {
      guard source.artifacts.contains(where: { $0.role == .nodeInterpreter }) else { continue }
      let migrationID = installationID(for: source.id)
      var target = desktop.first {
        $0.executableIdentity.canonicalPath == source.executableIdentity.canonicalPath
      }
      if target == nil, namespaces[migrationID.rawValue] == nil {
        let migrated = try record(from: source, id: migrationID)
        try await store.insertAgentInstallation(migrated)
        desktop.append(migrated)
        target = migrated
      }
      guard let target, target.id == migrationID else { continue }
      namespaces[target.id.rawValue] = source.id.rawValue
      if source.id.rawValue == oldActive { active = target.id.rawValue }
    }
    try await settings.setDeepSeekHarnessDesktopNamespaces(namespaces)
    if active != oldActive {
      try await settings.set(active, for: .deepSeekHarnessDesktopActiveInstallationID)
    }
    return namespaces
  }

  private static func installationID(for legacy: AgentInstallationID) -> AgentInstallationID {
    let digest = SHA256.hash(data: Data(legacy.rawValue.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return .init(rawValue: "ainst-dsh-desktop-" + String(digest.prefix(32)))
  }

  private static func record(from source: ServiceAgentInstallationRecord, id: AgentInstallationID)
    throws -> ServiceAgentInstallationRecord
  {
    let date = Date()
    return try .init(
      id: id, providerID: .deepSeekHarnessDesktop, displayName: "DSH 桌面",
      executablePath: source.executablePath, executableIdentity: source.executableIdentity,
      version: source.version, protocolRevision: "codex-bridge-dsh/1", adapterRevision: 11,
      trustProfile: .userTrusted, securityProfileID: nil, isEnabled: source.isEnabled,
      availability: .unavailable, capabilities: .empty,
      artifacts: source.artifacts.filter { $0.role == .nodeInterpreter },
      runtimeArtifacts: source.runtimeArtifacts, lastProbeError: "等待 DSH 桌面连接。",
      createdAt: date, updatedAt: date)
  }
}

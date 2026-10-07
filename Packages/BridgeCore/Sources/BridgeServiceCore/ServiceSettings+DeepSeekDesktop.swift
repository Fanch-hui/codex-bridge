import BridgeAgentCore
import Foundation

public struct ServiceDeepSeekDesktopTrust: Codable, Equatable, Sendable {
  public let profileID: String
  public let publicKey: String
  public init(profileID: String, publicKey: String) {
    self.profileID = profileID
    self.publicKey = publicKey
  }
}

extension ServiceSettings {
  public func deepSeekHarnessConnectionSelection() async throws
    -> (mode: String?, activeInstallationID: String?)
  {
    let values = try await store.settingValues(keys: [
      ServiceSettingKey.deepSeekHarnessConnectionMode.rawValue,
      ServiceSettingKey.deepSeekHarnessDesktopActiveInstallationID.rawValue,
    ])
    return (
      values[ServiceSettingKey.deepSeekHarnessConnectionMode.rawValue].flatMap {
        $0.isEmpty ? nil : $0
      },
      values[ServiceSettingKey.deepSeekHarnessDesktopActiveInstallationID.rawValue].flatMap {
        $0.isEmpty ? nil : $0
      }
    )
  }

  public func setDeepSeekHarnessConnectionSelection(
    mode: String?, activeInstallationID: String?
  ) async throws {
    let updatedAt = now()
    try await store.setSettings([
      .init(
        key: ServiceSettingKey.deepSeekHarnessConnectionMode.rawValue,
        value: mode ?? "", updatedAt: updatedAt),
      .init(
        key: ServiceSettingKey.deepSeekHarnessDesktopActiveInstallationID.rawValue,
        value: activeInstallationID ?? "", updatedAt: updatedAt),
    ])
  }

  public func deepSeekHarnessConnectionMode() async throws -> DeepSeekHarnessConnectionMode {
    guard let raw = try await string(for: .deepSeekHarnessConnectionMode) else { return .acp }
    guard let mode = DeepSeekHarnessConnectionMode(rawValue: raw) else {
      throw ServiceStoreError.corruptRecord
    }
    return mode
  }

  public func deepSeekHarnessDesktopTrust(installationID: AgentInstallationID) async throws
    -> ServiceDeepSeekDesktopTrust?
  {
    let namespace = try await deepSeekHarnessDesktopNamespace(for: installationID)
    return try await deepSeekDesktopTrusts()[namespace.rawValue]
  }

  public func setDeepSeekHarnessDesktopTrust(
    _ trust: ServiceDeepSeekDesktopTrust?,
    installationID: AgentInstallationID
  ) async throws {
    let namespace = try await deepSeekHarnessDesktopNamespace(for: installationID)
    var trusts = try await deepSeekDesktopTrusts()
    trusts[namespace.rawValue] = trust
    let value = try JSONEncoder().encode(trusts)
    try await set(String(decoding: value, as: UTF8.self), for: .deepSeekHarnessDesktopTrust)
  }

  private func deepSeekDesktopTrusts() async throws -> [String: ServiceDeepSeekDesktopTrust] {
    guard let raw = try await string(for: .deepSeekHarnessDesktopTrust) else { return [:] }
    guard
      let trusts = try? JSONDecoder().decode(
        [String: ServiceDeepSeekDesktopTrust].self,
        from: Data(raw.utf8))
    else { throw ServiceStoreError.corruptRecord }
    return trusts
  }
}

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
    try await deepSeekDesktopTrusts()[installationID.rawValue]
  }

  public func setDeepSeekHarnessDesktopTrust(
    _ trust: ServiceDeepSeekDesktopTrust?,
    installationID: AgentInstallationID
  ) async throws {
    var trusts = try await deepSeekDesktopTrusts()
    trusts[installationID.rawValue] = trust
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

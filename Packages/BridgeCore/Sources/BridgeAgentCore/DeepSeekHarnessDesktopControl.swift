import Foundation

public struct DeepSeekHarnessDesktopStatus: Codable, Equatable, Sendable {
  public let connected: Bool
  public let paired: Bool
  public let profileID: String?
  public let instanceID: String?
  public let pairingCode: String?
  public let protocolRevision: String?
  public let unavailableReason: String?
  public let errorCode: String?

  public init(
    connected: Bool, paired: Bool, profileID: String? = nil, instanceID: String? = nil,
    pairingCode: String? = nil, protocolRevision: String? = nil, unavailableReason: String? = nil,
    errorCode: String? = nil
  ) {
    self.connected = connected
    self.paired = paired
    self.profileID = profileID
    self.instanceID = instanceID
    self.pairingCode = pairingCode
    self.protocolRevision = protocolRevision
    self.unavailableReason = unavailableReason
    self.errorCode = errorCode
  }
}

public struct DeepSeekHarnessDesktopDefaults: Codable, Equatable, Sendable {
  public let modelID: String?
  public let effort: String?
  public init(modelID: String?, effort: String?) {
    self.modelID = modelID
    self.effort = effort
  }
}

public protocol DeepSeekHarnessDesktopControlling: Sendable {
  func status(installation: AgentInstallation) async throws -> DeepSeekHarnessDesktopStatus
  func pair(installation: AgentInstallation) async throws -> DeepSeekHarnessDesktopStatus
  func revoke(installation: AgentInstallation) async throws
  func openSession(sessionID: String, projectRoot: String, installation: AgentInstallation)
    async throws
  func defaults(installation: AgentInstallation) async throws -> DeepSeekHarnessDesktopDefaults
  func setDefaults(modelID: String?, effort: String?, installation: AgentInstallation) async throws
    -> DeepSeekHarnessDesktopDefaults
}

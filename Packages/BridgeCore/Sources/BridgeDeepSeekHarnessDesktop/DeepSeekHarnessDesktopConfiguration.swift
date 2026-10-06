import BridgeAgentCore
import Foundation

public struct DeepSeekHarnessDesktopTrust: Codable, Equatable, Sendable {
  public let profileID: String
  public let publicKey: String

  public init(profileID: String, publicKey: String) {
    self.profileID = profileID
    self.publicKey = publicKey
  }
}

public struct DeepSeekHarnessDesktopConfiguration: Sendable {
  public typealias IndexLookup =
    @Sendable (AgentNativeSessionDirectoryScope, String, String) async throws -> Bool
  public typealias IndexSave =
    @Sendable (AgentNativeSessionDirectoryScope, String, String) async throws -> Void

  public let descriptorPathProvider: @Sendable (AgentInstallationID) -> String
  public let descriptorProvider:
    @Sendable (String, AgentInstallation) throws -> DeepSeekHarnessDesktopDescriptor
  public let identityProvider: @Sendable () async throws -> Data
  public let trustProvider:
    @Sendable (AgentInstallationID) async throws -> DeepSeekHarnessDesktopTrust?
  public let saveTrust:
    @Sendable (AgentInstallationID, DeepSeekHarnessDesktopTrust?) async throws -> Void
  public let indexLookup: IndexLookup
  public let indexSave: IndexSave
  public let registeredProjectPaths: @Sendable () async throws -> [String]
  public let installConnector:
    @Sendable (AgentInstallation) async throws -> DeepSeekHarnessDesktopStatus
  public let requestTimeout: Duration
  public let transportFactory: DeepSeekHarnessDesktopTransportFactory

  public init(
    descriptorPathProvider: @escaping @Sendable (AgentInstallationID) -> String,
    identityProvider: @escaping @Sendable () async throws -> Data,
    trustProvider:
      @escaping @Sendable (AgentInstallationID) async throws -> DeepSeekHarnessDesktopTrust?,
    saveTrust:
      @escaping @Sendable (AgentInstallationID, DeepSeekHarnessDesktopTrust?) async throws -> Void,
    indexLookup: @escaping IndexLookup,
    indexSave: @escaping IndexSave,
    registeredProjectPaths: @escaping @Sendable () async throws -> [String],
    descriptorProvider:
      @escaping @Sendable (String, AgentInstallation) throws -> DeepSeekHarnessDesktopDescriptor = {
        try DeepSeekHarnessDesktopDescriptor.load(path: $0, installation: $1)
      },
    installConnector:
      @escaping @Sendable (AgentInstallation) async throws -> DeepSeekHarnessDesktopStatus = { _ in
        throw AgentRuntimeError.processUnavailable
      },
    requestTimeout: Duration = .seconds(30),
    transportFactory: @escaping DeepSeekHarnessDesktopTransportFactory = {
      try await DeepSeekHarnessDesktopSocket.connect(port: $0)
    }
  ) {
    self.descriptorPathProvider = descriptorPathProvider
    self.descriptorProvider = descriptorProvider
    self.identityProvider = identityProvider
    self.trustProvider = trustProvider
    self.saveTrust = saveTrust
    self.indexLookup = indexLookup
    self.indexSave = indexSave
    self.registeredProjectPaths = registeredProjectPaths
    self.installConnector = installConnector
    self.requestTimeout = requestTimeout
    self.transportFactory = transportFactory
  }
}

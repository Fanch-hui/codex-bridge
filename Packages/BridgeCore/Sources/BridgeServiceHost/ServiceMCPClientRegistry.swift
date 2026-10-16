import BridgeMCP
import BridgeServiceCore
import Foundation

public struct ServiceMCPClientProfile: Equatable, Sendable {
  public let clientID: MCPClientID
  public let displayName: String
  public let enabled: Bool
  public let exposureMode: MCPServiceExposureMode

  public init(
    clientID: MCPClientID,
    displayName: String,
    enabled: Bool,
    exposureMode: MCPServiceExposureMode
  ) {
    self.clientID = clientID
    self.displayName = displayName
    self.enabled = enabled
    self.exposureMode = exposureMode
  }
}

public enum ServiceMCPClientRegistryError: Error, Equatable, Sendable {
  case unsupportedClient
  case clientDisabled
}

public actor ServiceMCPClientRegistry {
  public let authenticator: MCPClientCredentialAuthenticator
  public let admission: MCPClientAdmissionGate

  private static let localClients: [MCPClientID] = [.qwenStudio, .gemini]
  private let settings: ServiceSettings
  private let secrets: ServiceMCPSecretProvider
  private let mutationGate = AsyncMutex()

  /// Defers credential-store access until the local listener is prepared.
  public static func makeDeferred(
    settings: ServiceSettings,
    secrets: ServiceMCPSecretProvider
  ) throws -> ServiceMCPClientRegistry {
    ServiceMCPClientRegistry(settings: settings, secrets: secrets)
  }

  public static func make(
    settings: ServiceSettings,
    secrets: ServiceMCPSecretProvider
  ) async throws -> ServiceMCPClientRegistry {
    let registry = try makeDeferred(settings: settings, secrets: secrets)
    try await registry.prepareForLocalMCP()
    return registry
  }

  private init(settings: ServiceSettings, secrets: ServiceMCPSecretProvider) {
    self.settings = settings
    self.secrets = secrets
    authenticator = MCPClientCredentialAuthenticator()
    admission = MCPClientAdmissionGate(initiallyEnabled: [])
  }

  public func profiles() async throws -> [ServiceMCPClientProfile] {
    var profiles = [
      ServiceMCPClientProfile(
        clientID: .chatGPT,
        displayName: "ChatGPT",
        enabled: true,
        exposureMode: Self.mcpMode(try await settings.exposureMode())
      )
    ]
    for clientID in Self.localClients {
      profiles.append(
        ServiceMCPClientProfile(
          clientID: clientID,
          displayName: clientID == .gemini ? "Gemini" : "Qwen Studio",
          enabled: try await isConfiguredEnabled(clientID) && admission.isEnabled(clientID),
          exposureMode: await exposureMode(for: clientID)
        )
      )
    }
    return profiles
  }

  public func exposureMode(for clientID: MCPClientID) async -> MCPServiceExposureMode {
    do {
      switch clientID {
      case .chatGPT: return Self.mcpMode(try await settings.exposureMode())
      case .qwenStudio: return Self.mcpMode(try await settings.qwenStudioExposureMode())
      case .gemini: return Self.mcpMode(try await settings.geminiExposureMode())
      default: return .readOnly
      }
    } catch {
      return .readOnly
    }
  }

  public func setEnabled(_ enabled: Bool, for clientID: MCPClientID) async throws {
    try requireLocalClient(clientID)
    await mutationGate.acquire()
    defer { mutationGate.release() }
    admission.revoke(clientID)
    do {
      try await installCredentials(excluding: clientID)
      if enabled { _ = try await secrets.secret(for: clientID) }
      try await setConfiguredEnabled(enabled, for: clientID)
      try await installCredentials()
      if enabled { admission.allow(clientID) }
    } catch {
      try? await setConfiguredEnabled(false, for: clientID)
      try? await installCredentials(excluding: clientID)
      throw error
    }
  }

  public func setExposureMode(
    _ mode: MCPServiceExposureMode,
    for clientID: MCPClientID
  ) async throws {
    switch clientID {
    case .qwenStudio: try await settings.setQwenStudioExposureMode(Self.serviceMode(mode))
    case .gemini: try await settings.setGeminiExposureMode(Self.serviceMode(mode))
    default: throw ServiceMCPClientRegistryError.unsupportedClient
    }
  }

  public func rotateCredential(for clientID: MCPClientID) async throws {
    try requireLocalClient(clientID)
    await mutationGate.acquire()
    defer { mutationGate.release() }
    admission.revoke(clientID)
    do {
      let wasEnabled = try await isConfiguredEnabled(clientID)
      try await installCredentials(excluding: clientID)
      _ = try await secrets.rotate(clientID: clientID)
      try await installCredentials()
      if wasEnabled { admission.allow(clientID) }
    } catch {
      try? await setConfiguredEnabled(false, for: clientID)
      try? await installCredentials(excluding: clientID)
      throw error
    }
  }

  public func credential(for clientID: MCPClientID) async throws -> String {
    try requireLocalClient(clientID)
    await mutationGate.acquire()
    defer { mutationGate.release() }
    guard try await isConfiguredEnabled(clientID), admission.isEnabled(clientID) else {
      throw ServiceMCPClientRegistryError.clientDisabled
    }
    return try await secrets.secret(for: clientID)
  }

  public func setQwenStudioEnabled(_ enabled: Bool) async throws {
    try await setEnabled(enabled, for: .qwenStudio)
  }

  public func setQwenStudioExposureMode(_ mode: MCPServiceExposureMode) async throws {
    try await setExposureMode(mode, for: .qwenStudio)
  }

  public func rotateQwenStudioCredential() async throws {
    try await rotateCredential(for: .qwenStudio)
  }

  public func qwenStudioCredential() async throws -> String {
    try await credential(for: .qwenStudio)
  }

  public func chatGPTCredential() async throws -> String {
    try await secrets.secret(for: .chatGPT)
  }

  public func prepareForLocalMCP() async throws {
    await mutationGate.acquire()
    defer { mutationGate.release() }
    try await installCredentials()
    admission.allow(.chatGPT)
    for clientID in Self.localClients {
      if try await isConfiguredEnabled(clientID) {
        admission.allow(clientID)
      } else {
        admission.revoke(clientID)
      }
    }
  }

  private func installCredentials(excluding excluded: MCPClientID? = nil) async throws {
    var credentials = [
      try MCPClientCredential(clientID: .chatGPT, value: try await secrets.secret(for: .chatGPT))
    ]
    for clientID in Self.localClients where clientID != excluded {
      if try await isConfiguredEnabled(clientID) {
        credentials.append(
          try MCPClientCredential(
            clientID: clientID, value: try await secrets.secret(for: clientID))
        )
      }
    }
    try authenticator.replaceCredentials(credentials)
  }

  private func requireLocalClient(_ clientID: MCPClientID) throws {
    guard Self.localClients.contains(clientID) else {
      throw ServiceMCPClientRegistryError.unsupportedClient
    }
  }

  private func isConfiguredEnabled(_ clientID: MCPClientID) async throws -> Bool {
    switch clientID {
    case .qwenStudio: try await settings.qwenStudioEnabled()
    case .gemini: try await settings.geminiEnabled()
    default: throw ServiceMCPClientRegistryError.unsupportedClient
    }
  }

  private func setConfiguredEnabled(_ enabled: Bool, for clientID: MCPClientID) async throws {
    switch clientID {
    case .qwenStudio: try await settings.setQwenStudioEnabled(enabled)
    case .gemini: try await settings.setGeminiEnabled(enabled)
    default: throw ServiceMCPClientRegistryError.unsupportedClient
    }
  }

  private static func mcpMode(_ mode: ServiceMCPExposureMode) -> MCPServiceExposureMode {
    switch mode {
    case .readOnly: .readOnly
    case .full: .full
    }
  }

  private static func serviceMode(_ mode: MCPServiceExposureMode) -> ServiceMCPExposureMode {
    switch mode {
    case .readOnly: .readOnly
    case .full: .full
    }
  }
}

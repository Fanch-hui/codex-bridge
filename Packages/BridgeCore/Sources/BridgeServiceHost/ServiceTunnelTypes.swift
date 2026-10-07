import BridgeSecurity
import BridgeTunnel
import Foundation

public struct ServiceTunnelSnapshot: Equatable, Sendable {
  public let configured: Bool
  public let enabled: Bool
  public let helperAvailable: Bool
  public let tunnelID: String?
  public let lifecycle: TunnelLifecycle
  public let acceptsRemoteSubmissions: Bool
  public let actionRequired: Bool
  public let httpProxy: String?

  public init(
    configured: Bool,
    enabled: Bool,
    helperAvailable: Bool,
    tunnelID: String?,
    lifecycle: TunnelLifecycle,
    acceptsRemoteSubmissions: Bool,
    actionRequired: Bool,
    httpProxy: String? = nil
  ) {
    self.configured = configured
    self.enabled = enabled
    self.helperAvailable = helperAvailable
    self.tunnelID = tunnelID
    self.lifecycle = lifecycle
    self.acceptsRemoteSubmissions = acceptsRemoteSubmissions
    self.actionRequired = actionRequired
    self.httpProxy = httpProxy
  }

  public static func unconfigured(
    helperAvailable: Bool,
    httpProxy: String? = nil
  ) -> ServiceTunnelSnapshot {
    ServiceTunnelSnapshot(
      configured: false,
      enabled: false,
      helperAvailable: helperAvailable,
      tunnelID: nil,
      lifecycle: .stopped,
      acceptsRemoteSubmissions: false,
      actionRequired: false,
      httpProxy: httpProxy
    )
  }
}

public enum ServiceTunnelError: Error, Equatable, LocalizedError, Sendable {
  case invalidRuntimeKey
  case notConfigured
  case localMCPUnavailable
  case helperUnavailable
  case invalidStoredConfiguration
  case secretStoreUnavailable
  case serviceStopped
  case startFailed
  case httpProxyUnsupported

  public var errorDescription: String? {
    switch self {
    case .invalidRuntimeKey:
      "The Tunnel Runtime Key is invalid."
    case .notConfigured:
      "Secure MCP Tunnel is not configured."
    case .localMCPUnavailable:
      "The local MCP endpoint is unavailable."
    case .helperUnavailable:
      "The signed tunnel-client helper is not available in this App build."
    case .invalidStoredConfiguration:
      "The stored Tunnel configuration is invalid."
    case .secretStoreUnavailable:
      "The Tunnel Runtime Key is unavailable in Keychain."
    case .serviceStopped:
      "The background Service is stopping."
    case .startFailed:
      "Secure MCP Tunnel could not start."
    case .httpProxyUnsupported:
      "The Tunnel manager does not support an HTTP proxy."
    }
  }
}

public protocol ServiceTunnelManaging: Sendable {
  func start() async throws
  func stop() async
  func state() async -> TunnelLifecycle
  func acceptsRemoteSubmissions() async -> Bool
  func diagnostics() async -> TunnelDiagnostics
}

extension TunnelManager: ServiceTunnelManaging {}

public protocol ServiceTunnelManagerBuilding: Sendable {
  func helperAvailable() -> Bool

  func make(
    tunnelID: TunnelID,
    runtimeKeyReference: SecretReference,
    localMCPURL: URL,
    localMCPHeaderSecret: String
  ) async throws -> any ServiceTunnelManaging

  func make(
    tunnelID: TunnelID,
    runtimeKeyReference: SecretReference,
    localMCPURL: URL,
    localMCPHeaderSecret: String,
    httpProxy: TunnelHTTPProxy?
  ) async throws -> any ServiceTunnelManaging
}

extension ServiceTunnelManagerBuilding {
  public func make(
    tunnelID: TunnelID,
    runtimeKeyReference: SecretReference,
    localMCPURL: URL,
    localMCPHeaderSecret: String,
    httpProxy: TunnelHTTPProxy?
  ) async throws -> any ServiceTunnelManaging {
    guard httpProxy == nil else { throw ServiceTunnelError.httpProxyUnsupported }
    return try await make(
      tunnelID: tunnelID,
      runtimeKeyReference: runtimeKeyReference,
      localMCPURL: localMCPURL,
      localMCPHeaderSecret: localMCPHeaderSecret
    )
  }
}

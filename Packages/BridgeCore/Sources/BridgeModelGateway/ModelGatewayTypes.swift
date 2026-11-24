import Foundation

public struct ModelGatewayConfiguration: Sendable {
  public let port: Int
  public let maximumConnections: Int
  public let maximumRequests: Int
  public let maximumHeaderBytes: Int
  public let maximumBodyBytes: Int
  public let maximumResponseChunkBytes: Int

  public init(
    port: Int, maximumConnections: Int = 64, maximumRequests: Int = 40,
    maximumHeaderBytes: Int = 32 * 1024, maximumBodyBytes: Int = 16 * 1024 * 1024,
    maximumResponseChunkBytes: Int = 1024 * 1024
  ) throws {
    guard (0...65535).contains(port), maximumConnections > 0, maximumRequests > 0,
      maximumHeaderBytes > 0, maximumBodyBytes > 0, maximumResponseChunkBytes > 0
    else { throw ModelGatewayError.invalidConfiguration }
    self.port = port
    self.maximumConnections = maximumConnections
    self.maximumRequests = maximumRequests
    self.maximumHeaderBytes = maximumHeaderBytes
    self.maximumBodyBytes = maximumBodyBytes
    self.maximumResponseChunkBytes = maximumResponseChunkBytes
  }
}

public struct ModelGatewayEndpoint: Sendable, Equatable {
  public let host: String
  public let port: Int
}

public struct ModelGatewayClientContext: Sendable, Equatable {
  public let clientID: String
  public let generation: UInt64
  public let authenticatedViaBridgeHeader: Bool
  public let authenticatedViaCodexGatewayHeader: Bool

  public init(
    clientID: String, generation: UInt64, authenticatedViaBridgeHeader: Bool = false,
    authenticatedViaCodexGatewayHeader: Bool = false
  ) {
    self.clientID = clientID
    self.generation = generation
    self.authenticatedViaBridgeHeader = authenticatedViaBridgeHeader
    self.authenticatedViaCodexGatewayHeader = authenticatedViaCodexGatewayHeader
  }
}

/// Authentication material must never be returned in a request or response.
public struct ModelGatewayCredentials: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let authorization: [String]
  public let apiKey: [String]
  public let bridgeToken: [String]
  public let codexGatewayToken: [String]

  public init(
    authorization: [String], apiKey: [String], bridgeToken: [String] = [],
    codexGatewayToken: [String] = []
  ) {
    self.authorization = authorization
    self.apiKey = apiKey
    self.bridgeToken = bridgeToken
    self.codexGatewayToken = codexGatewayToken
  }

  public var description: String { "ModelGatewayCredentials(<redacted>)" }
  public var debugDescription: String { description }
}

/// Redacted upstream auth headers preserved only for explicit official passthrough clients.
public struct ModelGatewayUpstreamAuth: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let authorization: String?
  public let apiKey: String?
  public let chatGPTAccountID: String?

  public init(
    authorization: String? = nil, apiKey: String? = nil, chatGPTAccountID: String? = nil
  ) {
    self.authorization = authorization
    self.apiKey = apiKey
    self.chatGPTAccountID = chatGPTAccountID
  }

  public var hasCredential: Bool {
    !(authorization ?? "").isEmpty || !(apiKey ?? "").isEmpty
  }

  public var description: String { "ModelGatewayUpstreamAuth(<redacted>)" }
  public var debugDescription: String { description }
}

public struct ModelGatewayRequest: Sendable {
  public let method: String
  public let path: String
  public let query: String?
  /// Lowercase names, with authentication headers omitted.
  public let headers: [String: String]
  public let body: Data
  public let client: ModelGatewayClientContext
  /// Present only when authenticated with an authorized official-passthrough header.
  public let upstreamAuth: ModelGatewayUpstreamAuth?

  public init(
    method: String, path: String, query: String? = nil, headers: [String: String], body: Data,
    client: ModelGatewayClientContext, upstreamAuth: ModelGatewayUpstreamAuth? = nil
  ) {
    self.method = method
    self.path = path
    self.query = query
    self.headers = headers
    self.body = body
    self.client = client
    self.upstreamAuth = upstreamAuth
  }
}

public typealias ModelGatewayAuthenticate =
  @Sendable (ModelGatewayCredentials) -> ModelGatewayClientContext?
public typealias ModelGatewayRequestHandler =
  @Sendable (ModelGatewayRequest, ModelGatewayResponseSink) async throws -> Void

public enum ModelGatewayError: Error, Sendable, Equatable {
  case invalidConfiguration
  case lifecycleTransitionInProgress
  case unexpectedBindAddress
  case responseAlreadyStarted
  case responseNotStarted
  case responseFinished
  case invalidResponse
  case responseChunkTooLarge
  case channelClosed
}

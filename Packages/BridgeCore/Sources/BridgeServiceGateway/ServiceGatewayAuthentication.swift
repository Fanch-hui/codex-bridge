import BridgeMCP
import BridgeModelGateway
import Foundation

/// Publishes credentials and authorization generations atomically to the HTTP event loop.
package final class ServiceGatewayAuthentication: @unchecked Sendable {
  private let lock = NSLock()
  private var authenticator = MCPClientCredentialAuthenticator()
  private var generations: [String: UInt64] = [:]
  private var models: [String: [String]] = [:]
  private var anthropicPassthroughClients: Set<String> = []
  private var codexPassthroughClients: Set<String> = []

  package func publish(_ clients: [ServiceExternalGatewayCredential]) throws {
    let credentials = try clients.map {
      try MCPClientCredential(clientID: MCPClientID(rawValue: $0.id), value: $0.token)
    }
    let next = MCPClientCredentialAuthenticator()
    if !credentials.isEmpty { try next.replaceCredentials(credentials) }
    lock.withLock {
      authenticator = next
      generations = Dictionary(uniqueKeysWithValues: clients.map { ($0.id, $0.generation) })
      models = Dictionary(uniqueKeysWithValues: clients.map { ($0.id, $0.models) })
      anthropicPassthroughClients = Set(
        clients.filter(\.allowsAnthropicPassthrough).map(\.id))
      codexPassthroughClients = Set(clients.filter(\.allowsCodexPassthrough).map(\.id))
    }
  }

  func authorizedModels(_ context: ModelGatewayClientContext) -> [String]? {
    lock.withLock {
      guard generations[context.clientID] == context.generation else { return nil }
      return models[context.clientID]
    }
  }

  func allowsAnthropicPassthrough(_ context: ModelGatewayClientContext) -> Bool {
    guard context.authenticatedViaBridgeHeader else { return false }
    return lock.withLock {
      generations[context.clientID] == context.generation
        && anthropicPassthroughClients.contains(context.clientID)
    }
  }

  func allowsCodexPassthrough(_ context: ModelGatewayClientContext) -> Bool {
    guard context.authenticatedViaCodexGatewayHeader else { return false }
    return lock.withLock {
      generations[context.clientID] == context.generation
        && codexPassthroughClients.contains(context.clientID)
    }
  }

  func replace(_ credentials: [MCPClientCredential], generations: [String: UInt64]) throws {
    let next = MCPClientCredentialAuthenticator()
    if !credentials.isEmpty { try next.replaceCredentials(credentials) }
    lock.withLock {
      authenticator = next
      self.generations = generations
      anthropicPassthroughClients = []
      codexPassthroughClients = []
    }
  }

  func authenticate(_ credentials: ModelGatewayCredentials) -> ModelGatewayClientContext? {
    guard credentials.authorization.count <= 1, credentials.apiKey.count <= 1,
      credentials.bridgeToken.count <= 1, credentials.codexGatewayToken.count <= 1
    else { return nil }
    if let gatewayHeader = credentials.codexGatewayToken.first {
      guard credentials.bridgeToken.isEmpty, credentials.apiKey.isEmpty,
        gatewayHeader.hasPrefix("Bearer "), credentials.authorization.count == 1,
        let authorization = credentials.authorization.first, authorization.hasPrefix("Bearer "),
        gatewayHeader != authorization
      else { return nil }
      let token = String(gatewayHeader.dropFirst(7))
      let upstreamToken = authorization.dropFirst(7)
      guard !token.isEmpty, !upstreamToken.isEmpty,
        !token.contains(where: { $0.isWhitespace || $0 == "," }),
        !upstreamToken.contains(where: { $0.isWhitespace || $0 == "," })
      else { return nil }
      return lock.withLock {
        guard let id = authenticator.authenticate([token]),
          let generation = generations[id.rawValue],
          codexPassthroughClients.contains(id.rawValue)
        else { return nil }
        return ModelGatewayClientContext(
          clientID: id.rawValue, generation: generation, authenticatedViaCodexGatewayHeader: true)
      }
    }
    if credentials.bridgeToken.count == 1 {
      let token = credentials.bridgeToken[0]
      guard !token.isEmpty,
        credentials.authorization != ["Bearer \(token)"],
        credentials.apiKey != [token]
      else { return nil }
      return lock.withLock {
        guard let id = authenticator.authenticate([token]),
          let generation = generations[id.rawValue],
          anthropicPassthroughClients.contains(id.rawValue)
        else { return nil }
        return ModelGatewayClientContext(
          clientID: id.rawValue, generation: generation, authenticatedViaBridgeHeader: true)
      }
    }
    guard credentials.bridgeToken.isEmpty else { return nil }
    let values: [String]
    if credentials.authorization.count == 1,
      credentials.authorization[0].hasPrefix("Bearer ")
    {
      let bearer = String(credentials.authorization[0].dropFirst(7))
      guard credentials.apiKey.isEmpty || credentials.apiKey == [bearer] else { return nil }
      values = [bearer]
    } else if credentials.authorization.isEmpty, credentials.apiKey.count == 1 {
      values = credentials.apiKey
    } else {
      return nil
    }
    return lock.withLock {
      guard let id = authenticator.authenticate(values),
        let generation = generations[id.rawValue]
      else { return nil }
      return ModelGatewayClientContext(clientID: id.rawValue, generation: generation)
    }
  }
}

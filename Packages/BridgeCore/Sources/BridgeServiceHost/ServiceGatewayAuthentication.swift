import BridgeMCP
import BridgeModelGateway
import Foundation

/// Publishes credentials and authorization generations atomically to the HTTP event loop.
final class ServiceGatewayAuthentication: @unchecked Sendable {
  private let lock = NSLock()
  private var authenticator = MCPClientCredentialAuthenticator()
  private var generations: [String: UInt64] = [:]
  private var models: [String: [String]] = [:]
  private var anthropicPassthroughClients: Set<String> = []

  func publish(_ clients: [ServiceExternalGatewayCredential]) throws {
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

  func replace(_ credentials: [MCPClientCredential], generations: [String: UInt64]) throws {
    let next = MCPClientCredentialAuthenticator()
    if !credentials.isEmpty { try next.replaceCredentials(credentials) }
    lock.withLock {
      authenticator = next
      self.generations = generations
      anthropicPassthroughClients = []
    }
  }

  func authenticate(_ credentials: ModelGatewayCredentials) -> ModelGatewayClientContext? {
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

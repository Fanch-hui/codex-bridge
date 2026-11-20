import BridgeMCP
import BridgeSecurity
import BridgeServiceCore
import Foundation

public struct ServiceExternalMCPClient: Codable, Equatable, Sendable {
  public let id: String
  public var displayName: String
  public var enabled: Bool
  public var allowedProjectIDs: [String]
  public var allowedToolNames: [String]

  public init(
    id: String, displayName: String, enabled: Bool,
    allowedProjectIDs: [String], allowedToolNames: [String]
  ) {
    self.id = id
    self.displayName = displayName
    self.enabled = enabled
    self.allowedProjectIDs = allowedProjectIDs
    self.allowedToolNames = allowedToolNames
  }

  public static func isValidID(_ id: String) -> Bool {
    guard id.hasPrefix("external.") else { return false }
    let suffix = String(id.dropFirst("external.".count))
    return UUID(uuidString: suffix)?.uuidString.lowercased() == suffix
  }

  func validate() throws {
    guard Self.isValidID(id), !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      displayName.utf8.count <= 128, allowedProjectIDs.count <= 128,
      allowedProjectIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
      Set(allowedProjectIDs).count == allowedProjectIDs.count,
      Set(allowedToolNames).count == allowedToolNames.count,
      Set(allowedToolNames).isSubset(of: MCPClientAccess.externalToolNames)
    else { throw ServiceMCPClientRegistryError.invalidExternalClient }
  }
}

extension ServiceMCPClientRegistry {
  private static let externalClientsKey = "mcp.external_clients"
  private static let maximumExternalClients = 32

  public func externalClients() async throws -> [ServiceExternalMCPClient] {
    guard let store else { return [] }
    guard let value = try await store.setting(key: Self.externalClientsKey)?.value else {
      return []
    }
    let clients = try JSONDecoder().decode([ServiceExternalMCPClient].self, from: Data(value.utf8))
    guard clients.count <= Self.maximumExternalClients,
      Set(clients.map(\.id)).count == clients.count
    else { throw ServiceMCPClientRegistryError.invalidExternalClient }
    for client in clients { try client.validate() }
    return clients
  }

  public func registerExternal(displayName: String) async throws -> ServiceExternalMCPClient {
    await mutationGate.acquire()
    defer { mutationGate.release() }
    let old = try await externalClients()
    guard old.count < Self.maximumExternalClients else {
      throw ServiceMCPClientRegistryError.externalClientLimit
    }
    let client = ServiceExternalMCPClient(
      id: "external.\(UUID().uuidString.lowercased())", displayName: displayName,
      enabled: false, allowedProjectIDs: [], allowedToolNames: ["bridge_status", "list_projects"]
    )
    try client.validate()
    try await replaceExternalClients(old + [client], previously: old, changedID: client.id)
    return client
  }

  public func updateExternal(_ client: ServiceExternalMCPClient) async throws {
    await mutationGate.acquire()
    defer { mutationGate.release() }
    try client.validate()
    let old = try await externalClients()
    guard let index = old.firstIndex(where: { $0.id == client.id }) else {
      throw ServiceMCPClientRegistryError.unsupportedClient
    }
    var updated = old
    updated[index] = client
    try await replaceExternalClients(updated, previously: old, changedID: client.id)
  }

  public func removeExternal(id: String) async throws {
    await mutationGate.acquire()
    defer { mutationGate.release() }
    let old = try await externalClients()
    guard old.contains(where: { $0.id == id }) else {
      throw ServiceMCPClientRegistryError.unsupportedClient
    }
    try await replaceExternalClients(old.filter { $0.id != id }, previously: old, changedID: id)
    do {
      try await secrets.remove(clientID: MCPClientID(rawValue: id))
    } catch SecretStoreError.notFound {
      // A disabled client may never have created a secret.
    }
  }

  public func access(for clientID: MCPClientID) async -> MCPClientAccess {
    if clientID == .chatGPT || clientID == .qwenStudio || clientID == .gemini {
      return .unrestricted
    }
    guard let clients = try? await externalClients(),
      let client = clients.first(where: { $0.id == clientID.rawValue && $0.enabled }),
      admission.isEnabled(clientID)
    else { return .denied }
    return .restricted(
      projectIDs: Set(client.allowedProjectIDs), toolNames: Set(client.allowedToolNames))
  }

  private func replaceExternalClients(
    _ clients: [ServiceExternalMCPClient], previously: [ServiceExternalMCPClient],
    changedID: String
  ) async throws {
    guard let store else { throw ServiceMCPClientRegistryError.externalStoreUnavailable }
    let clientID = MCPClientID(rawValue: changedID)
    admission.revoke(clientID)
    do {
      try await writeExternalClients(clients, store: store)
      try await installCredentials()
      if clients.contains(where: { $0.id == changedID && $0.enabled }) {
        admission.allow(clientID)
      }
    } catch {
      try await writeExternalClients(previously, store: store)
      try await installCredentials(excluding: clientID)
      throw error
    }
  }

  private func writeExternalClients(
    _ clients: [ServiceExternalMCPClient], store: SimpleServiceStore
  )
    async throws
  {
    let data = try JSONEncoder().encode(clients)
    let value = String(decoding: data, as: UTF8.self)
    try await store.setSetting(
      ServiceSettingRecord(
        key: Self.externalClientsKey, value: value, updatedAt: Date()))
  }
}

import BridgeACP
import BridgeMCP
import BridgeSecurity
import BridgeServiceCore
import Foundation

struct ServiceExternalApplicationsCleanupFailure: Error {
  let operationError: any Error
  let cleanupError: any Error
}

struct ServiceExternalGatewayCredential: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  let id: String
  let token: String
  let generation: UInt64
  let models: [String]
  let allowsAnthropicPassthrough: Bool
  let allowsCodexPassthrough: Bool

  init(
    id: String, token: String, generation: UInt64, models: [String],
    allowsAnthropicPassthrough: Bool = false, allowsCodexPassthrough: Bool = false
  ) {
    self.id = id
    self.token = token
    self.generation = generation
    self.models = models
    self.allowsAnthropicPassthrough = allowsAnthropicPassthrough
    self.allowsCodexPassthrough = allowsCodexPassthrough
  }

  var description: String { "ServiceExternalGatewayCredential(id: \(id), token: <redacted>)" }
  var debugDescription: String { description }
}

struct ServiceExternalApplication: Codable, Equatable, Sendable {
  var id: String
  var name: String
  var platform: String?
  var enabled: Bool
  var models: [String]
  var mcpEnabled: Bool
  var projectIDs: [String]
  var allowCommands: Bool
  var preserveOfficialLogin: Bool = false
  var generation: UInt64

  init(
    id: String, name: String, platform: String?, enabled: Bool, models: [String],
    mcpEnabled: Bool, projectIDs: [String], allowCommands: Bool,
    preserveOfficialLogin: Bool = false, generation: UInt64
  ) {
    self.id = id
    self.name = name
    self.platform = platform
    self.enabled = enabled
    self.models = models
    self.mcpEnabled = mcpEnabled
    self.projectIDs = projectIDs
    self.allowCommands = allowCommands
    self.preserveOfficialLogin = preserveOfficialLogin
    self.generation = generation
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    platform = try container.decodeIfPresent(String.self, forKey: .platform)
    enabled = try container.decode(Bool.self, forKey: .enabled)
    models = try container.decode([String].self, forKey: .models)
    mcpEnabled = try container.decode(Bool.self, forKey: .mcpEnabled)
    projectIDs = try container.decode([String].self, forKey: .projectIDs)
    allowCommands = try container.decode(Bool.self, forKey: .allowCommands)
    preserveOfficialLogin =
      try container.decodeIfPresent(Bool.self, forKey: .preserveOfficialLogin) ?? false
    generation = try container.decode(UInt64.self, forKey: .generation)
  }

  var presentation: ACPJSONValue {
    var fields: [String: ACPJSONValue] = [
      "id": .string(id), "name": .string(name), "enabled": .bool(enabled),
      "models": .array(models.map(ACPJSONValue.string)), "mcpEnabled": .bool(mcpEnabled),
      "projectIDs": .array(projectIDs.map(ACPJSONValue.string)),
      "allowCommands": .bool(allowCommands),
      "preserveOfficialLogin": .bool(preserveOfficialLogin),
      "generation": .string(String(generation)),
    ]
    if let platform { fields["platform"] = .string(platform) }
    return .object(fields)
  }
}

struct ServiceExternalConnectionRecord: Codable, Equatable, Sendable {
  let receiptID: String
  let clientID: String
  let agent: String
  let purpose: String
  let scope: String
  let projectID: String?
  let model: String?
  let generation: UInt64
  let endpoint: String?
  var applied: Bool
  var replacesReceiptID: String? = nil
  var compatibility: [String: Bool]? = nil
}

actor ServiceExternalApplications {
  static let clientsKey = "provider_gateway.clients"
  static let connectionsKey = "provider_gateway.connections"
  let store: SimpleServiceStore
  let secrets: any SecretStore
  let mcpClients: ServiceMCPClientRegistry
  let projects: ServiceProjectService
  let editor: ExternalAgentConnection
  let appExecutable: URL
  let homeDirectory: URL
  let endpoint: @Sendable () async throws -> URL
  let modelNames: @Sendable () async -> [String: String]
  let modelLimits: @Sendable () async -> [String: ExternalAgentModelLimit]
  let codexTakeoverCatalog: @Sendable ([String]) async throws -> Data
  let authorizationChanged: @Sendable ([ServiceExternalGatewayCredential]) throws -> Void
  let mutationGate = AsyncMutex()
  var previews: [UUID: ServiceExternalConnectionRecord] = [:]
  var previewOrder: [UUID] = []

  init(
    store: SimpleServiceStore, secrets: any SecretStore, mcpClients: ServiceMCPClientRegistry,
    projects: ServiceProjectService, editor: ExternalAgentConnection, appExecutable: URL,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    endpoint: @escaping @Sendable () async throws -> URL,
    modelNames: @escaping @Sendable () async -> [String: String] = { [:] },
    modelLimits: @escaping @Sendable () async -> [String: ExternalAgentModelLimit] = { [:] },
    codexTakeoverCatalog: @escaping @Sendable ([String]) async throws -> Data = { _ in
      Data(#"{"models":[]}"#.utf8)
    },
    authorizationChanged: @escaping @Sendable ([ServiceExternalGatewayCredential]) throws -> Void
  ) {
    self.store = store
    self.secrets = secrets
    self.mcpClients = mcpClients
    self.projects = projects
    self.editor = editor
    self.appExecutable = appExecutable
    self.homeDirectory = homeDirectory
    self.endpoint = endpoint
    self.modelNames = modelNames
    self.modelLimits = modelLimits
    self.codexTakeoverCatalog = codexTakeoverCatalog
    self.authorizationChanged = authorizationChanged
  }

  func initialize() async throws {
    await mutationGate.acquire()
    defer { mutationGate.release() }
    try await reconcileConnections()
    let applications = try await readClients()
    for mcp in try await mcpClients.externalClients() {
      if let application = applications.first(where: { $0.id == mcp.id }) {
        let desired = mcpRecord(application)
        if mcp != desired { try await mcpClients.updateExternal(desired) }
      } else if mcp.enabled {
        var disabled = mcp
        disabled.enabled = false
        try await mcpClients.updateExternal(disabled)
      }
    }
    try publish(applications)
  }

  func clients() async throws -> [ACPJSONValue] {
    try await readClients().map(\.presentation)
  }

  func connections() async throws -> [ACPJSONValue] {
    try await readConnections().map { record in
      .object([
        "receiptID": .string(record.receiptID), "clientID": .string(record.clientID),
        "agent": .string(record.agent), "purpose": .string(record.purpose),
        "scope": .string(record.scope), "state": .string(record.applied ? "applied" : "pending"),
        "model": record.model.map(ACPJSONValue.string) ?? .null,
        "projectID": record.projectID.map(ACPJSONValue.string) ?? .null,
        "generation": .string(String(record.generation)),
        "compatibility": .object((record.compatibility ?? [:]).mapValues { .bool($0) }),
      ])
    }
  }

  func call(action: String, payload: ACPJSONValue) async throws -> ACPJSONValue {
    guard let fields = payload.objectValue else {
      throw ServiceStoreError.invalidArgument("external_application.payload")
    }
    await mutationGate.acquire()
    defer { mutationGate.release() }
    switch action {
    case "clients.create": return try await create(fields)
    case "clients.update": return try await update(fields)
    case "clients.revoke": return try await revoke(fields)
    case "clients.configuration": return try await configuration(fields)
    case "connections.preview": return try await preview(fields)
    case "connections.apply": return try await apply(fields)
    case "connections.revert": return try await revert(fields)
    default: throw ServiceStoreError.invalidArgument("external_application.action")
    }
  }

  func readClients() async throws -> [ServiceExternalApplication] {
    guard let value = try await store.setting(key: Self.clientsKey)?.value else { return [] }
    return try JSONDecoder().decode([ServiceExternalApplication].self, from: Data(value.utf8))
  }

  func writeClients(_ clients: [ServiceExternalApplication]) async throws {
    let data = try JSONEncoder().encode(clients)
    try await store.setSetting(
      ServiceSettingRecord(
        key: Self.clientsKey, value: String(decoding: data, as: UTF8.self), updatedAt: Date()))
  }

  func readConnections() async throws -> [ServiceExternalConnectionRecord] {
    guard let value = try await store.setting(key: Self.connectionsKey)?.value else { return [] }
    return try JSONDecoder().decode([ServiceExternalConnectionRecord].self, from: Data(value.utf8))
  }

  func writeConnections(_ connections: [ServiceExternalConnectionRecord]) async throws {
    let data = try JSONEncoder().encode(connections)
    try await store.setSetting(
      ServiceSettingRecord(
        key: Self.connectionsKey, value: String(decoding: data, as: UTF8.self), updatedAt: Date()))
  }

  func publish(_ clients: [ServiceExternalApplication], excluding excluded: String? = nil) throws {
    let credentials = try clients.filter { $0.enabled && $0.id != excluded }.map { client in
      ServiceExternalGatewayCredential(
        id: client.id, token: try token(client.id), generation: client.generation,
        models: client.models,
        allowsAnthropicPassthrough: client.platform == "claude" && client.preserveOfficialLogin,
        allowsCodexPassthrough: client.platform == "codex_desktop" && client.preserveOfficialLogin)
    }
    try authorizationChanged(credentials)
  }

  func token(_ id: String) throws -> String {
    let reference = try tokenReference(id)
    let value = try secrets.load(reference)
    guard let token = String(data: value, encoding: .utf8), token.utf8.count == 43 else {
      throw SecretStoreError.invalidStoredValue
    }
    return token
  }

  func tokenReference(_ id: String) throws -> SecretReference {
    guard ServiceExternalMCPClient.isValidID(id) else {
      throw ServiceStoreError.invalidArgument("external_application.id")
    }
    return try SecretReference(validating: "provider-gateway.client.\(id)")
  }

  func required(_ fields: [String: ACPJSONValue], _ name: String) throws -> String {
    guard let value = fields[name]?.stringValue, !value.isEmpty else {
      throw ServiceStoreError.invalidArgument("external_application.\(name)")
    }
    return value
  }
}

import BridgeAgentCore
import Foundation

public typealias ServiceDeepSeekHarnessMCPTransport = AgentMCPServerTransport

public struct ServiceDeepSeekHarnessMCPSecretInput: Equatable, Sendable {
  public let name: String
  public let value: String?

  public init(name: String, value: String? = nil) {
    self.name = name
    self.value = value
  }
}

public struct ServiceDeepSeekHarnessMCPSecretSummary: Equatable, Sendable {
  public let name: String
  public let hasValue: Bool

  public init(name: String, hasValue: Bool) {
    self.name = name
    self.hasValue = hasValue
  }
}

public struct ServiceDeepSeekHarnessMCPServerInput: Equatable, Sendable {
  public let id: String
  public let name: String
  public let enabled: Bool
  public let transport: ServiceDeepSeekHarnessMCPTransport
  public let command: String?
  public let args: [String]
  public let url: String?
  public let environment: [ServiceDeepSeekHarnessMCPSecretInput]
  public let headers: [ServiceDeepSeekHarnessMCPSecretInput]

  public init(
    id: String,
    name: String,
    enabled: Bool,
    transport: ServiceDeepSeekHarnessMCPTransport,
    command: String? = nil,
    args: [String] = [],
    url: String? = nil,
    environment: [ServiceDeepSeekHarnessMCPSecretInput] = [],
    headers: [ServiceDeepSeekHarnessMCPSecretInput] = []
  ) {
    self.id = id
    self.name = name
    self.enabled = enabled
    self.transport = transport
    self.command = command
    self.args = args
    self.url = url
    self.environment = environment
    self.headers = headers
  }
}

public struct ServiceDeepSeekHarnessMCPServerSummary: Equatable, Sendable {
  public let id: String
  public let name: String
  public let enabled: Bool
  public let transport: ServiceDeepSeekHarnessMCPTransport
  public let command: String?
  public let args: [String]
  public let url: String?
  public let environment: [ServiceDeepSeekHarnessMCPSecretSummary]
  public let headers: [ServiceDeepSeekHarnessMCPSecretSummary]

  public init(
    id: String,
    name: String,
    enabled: Bool,
    transport: ServiceDeepSeekHarnessMCPTransport,
    command: String?,
    args: [String],
    url: String?,
    environment: [ServiceDeepSeekHarnessMCPSecretSummary],
    headers: [ServiceDeepSeekHarnessMCPSecretSummary]
  ) {
    self.id = id
    self.name = name
    self.enabled = enabled
    self.transport = transport
    self.command = command
    self.args = args
    self.url = url
    self.environment = environment
    self.headers = headers
  }
}

public struct ServiceDeepSeekHarnessMCPServerRecord: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let enabled: Bool
  public let transport: ServiceDeepSeekHarnessMCPTransport
  public let command: String?
  public let args: [String]
  public let url: String?
  public let environmentNames: [String]
  public let headerNames: [String]

  public init(
    id: String,
    name: String,
    enabled: Bool,
    transport: ServiceDeepSeekHarnessMCPTransport,
    command: String? = nil,
    args: [String] = [],
    url: String? = nil,
    environmentNames: [String] = [],
    headerNames: [String] = []
  ) throws {
    try ServiceValidation.identifier(id, field: "dsh.mcp.id", maximumBytes: 128)
    try ServiceValidation.text(name, field: "dsh.mcp.name", maximumBytes: 256)
    switch transport {
    case .stdio:
      guard let command else { throw ServiceStoreError.invalidArgument("dsh.mcp.command") }
      try ServiceValidation.text(command, field: "dsh.mcp.command", maximumBytes: 8 * 1_024)
      guard url == nil else { throw ServiceStoreError.invalidArgument("dsh.mcp.url") }
    case .http:
      guard let url else { throw ServiceStoreError.invalidArgument("dsh.mcp.url") }
      try ServiceValidation.text(url, field: "dsh.mcp.url", maximumBytes: 4 * 1_024)
      guard command == nil else { throw ServiceStoreError.invalidArgument("dsh.mcp.command") }
    }
    guard args.count <= 128 else { throw ServiceStoreError.invalidArgument("dsh.mcp.args") }
    for arg in args {
      try ServiceValidation.text(
        arg, field: "dsh.mcp.args", maximumBytes: 4 * 1_024, allowEmpty: true)
    }
    try Self.validateNames(environmentNames, field: "dsh.mcp.environment")
    try Self.validateNames(headerNames, field: "dsh.mcp.headers")
    guard Set(environmentNames).count == environmentNames.count,
      Set(headerNames).count == headerNames.count
    else {
      throw ServiceStoreError.invalidArgument("dsh.mcp.secretNames")
    }
    self.id = id
    self.name = name
    self.enabled = enabled
    self.transport = transport
    self.command = command
    self.args = args
    self.url = url
    self.environmentNames = environmentNames
    self.headerNames = headerNames
  }

  private static func validateNames(_ names: [String], field: String) throws {
    guard names.count <= 128 else { throw ServiceStoreError.invalidArgument(field) }
    for name in names {
      try ServiceValidation.identifier(name, field: field, maximumBytes: 256)
    }
  }
}

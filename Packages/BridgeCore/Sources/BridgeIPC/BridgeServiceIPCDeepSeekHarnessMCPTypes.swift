import Foundation

public struct IPCDeepSeekHarnessMCPSecretInput: Codable, Equatable, Sendable {
  public let name: String
  public let value: String?

  public init(name: String, value: String? = nil) {
    self.name = name
    self.value = value
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case value
  }
}

public struct IPCDeepSeekHarnessMCPSecretSummary: Codable, Equatable, Sendable {
  public let name: String
  public let hasValue: Bool

  public init(name: String, hasValue: Bool) {
    self.name = name
    self.hasValue = hasValue
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case hasValue = "has_value"
  }
}

public struct IPCDeepSeekHarnessMCPServerInput: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let enabled: Bool
  public let transport: String
  public let command: String?
  public let args: [String]
  public let url: String?
  public let environment: [IPCDeepSeekHarnessMCPSecretInput]
  public let headers: [IPCDeepSeekHarnessMCPSecretInput]

  public init(
    id: String,
    name: String,
    enabled: Bool,
    transport: String,
    command: String? = nil,
    args: [String] = [],
    url: String? = nil,
    environment: [IPCDeepSeekHarnessMCPSecretInput] = [],
    headers: [IPCDeepSeekHarnessMCPSecretInput] = []
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

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case enabled
    case transport
    case command
    case args
    case url
    case environment
    case headers
  }
}

public struct IPCDeepSeekHarnessMCPServerSummary: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let enabled: Bool
  public let transport: String
  public let command: String?
  public let args: [String]
  public let url: String?
  public let environment: [IPCDeepSeekHarnessMCPSecretSummary]
  public let headers: [IPCDeepSeekHarnessMCPSecretSummary]

  public init(
    id: String,
    name: String,
    enabled: Bool,
    transport: String,
    command: String?,
    args: [String],
    url: String?,
    environment: [IPCDeepSeekHarnessMCPSecretSummary],
    headers: [IPCDeepSeekHarnessMCPSecretSummary]
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

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case enabled
    case transport
    case command
    case args
    case url
    case environment
    case headers
  }
}

public struct IPCDeepSeekHarnessMCPListResponse: Codable, Equatable, Sendable {
  public let servers: [IPCDeepSeekHarnessMCPServerSummary]

  public init(servers: [IPCDeepSeekHarnessMCPServerSummary]) {
    self.servers = servers
  }
}

public struct IPCDeepSeekHarnessMCPDeleteRequest: Codable, Equatable, Sendable {
  public let id: String

  public init(id: String) {
    self.id = id
  }
}

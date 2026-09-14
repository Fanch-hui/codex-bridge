import Foundation

public enum AgentMCPServerTransport: String, Codable, CaseIterable, Sendable {
  case stdio
  case http
}

/// A resolved MCP server definition passed to an Agent provider at launch or
/// session creation time. Values in environment and headers are already
/// resolved from the local secret store.
public struct AgentMCPServerConfiguration: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let transport: AgentMCPServerTransport
  public let command: String?
  public let args: [String]
  public let url: String?
  public let environment: [String: String]
  public let headers: [String: String]

  public init(
    id: String,
    name: String,
    transport: AgentMCPServerTransport,
    command: String? = nil,
    args: [String] = [],
    url: String? = nil,
    environment: [String: String] = [:],
    headers: [String: String] = [:]
  ) {
    self.id = id
    self.name = name
    self.transport = transport
    self.command = command
    self.args = args
    self.url = url
    self.environment = environment
    self.headers = headers
  }
}

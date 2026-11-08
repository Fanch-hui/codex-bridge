import BridgeACP
import BridgeAgentCore
import BridgeClaudeSDK
import BridgeQoderSDK
import BridgeServiceApplication
import Crypto
import Foundation

enum ServiceAgentMCPResources {
  static func claude(
    request: AgentExecutionRequest,
    configurations: [ServiceAgentMCPScope: ServiceDeepSeekHarnessMCPConfiguration]
  ) async throws -> ClaudeSessionResources {
    guard request.networkAccessRequested else { return ClaudeSessionResources() }
    guard let configuration = configurations[.claudeCode] else {
      throw AgentRuntimeError.invalidRequest("claude.mcp_scope")
    }
    let servers = try await configuration.enabledRuntimeConfigurations()
    let values = try Dictionary(
      uniqueKeysWithValues: servers.map { server in
        let identifier = SHA256.hash(data: Data(server.id.utf8))
          .map { String(format: "%02x", $0) }.joined()
        return ("bridge-" + identifier, try serverConfiguration(server))
      })
    return ClaudeSessionResources(mcpServers: values)
  }

  static func qoder(
    request: AgentExecutionRequest,
    installation: AgentInstallation,
    distribution: QoderDistribution,
    configurations: [ServiceAgentMCPScope: ServiceDeepSeekHarnessMCPConfiguration]
  ) async throws -> QoderSessionResources {
    guard request.networkAccessRequested else {
      return QoderSessionResources(selectedSkills: request.selectedSkills)
    }
    let scope: ServiceAgentMCPScope = distribution == .cn ? .qoderCN : .qoderInternational
    guard let configuration = configurations[scope] else {
      throw AgentRuntimeError.invalidRequest("qoder.mcp_scope")
    }
    let servers = try await configuration.enabledRuntimeConfigurations()
    let values = try Dictionary(
      uniqueKeysWithValues: servers.map { server in
        let identifier = SHA256.hash(data: Data(server.id.utf8)).map { String(format: "%02x", $0) }
          .joined()
        return ("bridge-" + identifier, try serverConfiguration(server))
      })
    return QoderSessionResources(selectedSkills: request.selectedSkills, mcpServers: values)
  }

  private static func serverConfiguration(_ server: AgentMCPServerConfiguration) throws
    -> ACPJSONValue
  {
    switch server.transport {
    case .stdio:
      guard let command = server.command else {
        throw AgentRuntimeError.invalidRequest("mcp.command")
      }
      return .object([
        "type": .string("stdio"), "command": .string(command),
        "args": .array(server.args.map(ACPJSONValue.string)),
        "env": .object(server.environment.mapValues(ACPJSONValue.string)),
      ])
    case .http:
      guard let url = server.url else { throw AgentRuntimeError.invalidRequest("mcp.url") }
      return .object([
        "type": .string("http"), "url": .string(url),
        "headers": .object(server.headers.mapValues(ACPJSONValue.string)),
      ])
    }
  }
}

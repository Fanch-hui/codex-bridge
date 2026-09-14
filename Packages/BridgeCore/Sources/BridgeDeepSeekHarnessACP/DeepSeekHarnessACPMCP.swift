import BridgeACP
import BridgeAgentCore
import Foundation

enum DeepSeekHarnessACPMCP {
  static func parameters(
    servers: [AgentMCPServerConfiguration],
    initialization: DeepSeekHarnessACPInitialization,
    networkAllowed: Bool
  ) throws -> [ACPJSONValue] {
    let permitted = servers.filter { $0.transport == .stdio || networkAllowed }
    guard permitted.isEmpty || initialization.supportsMCPHTTP else {
      throw AgentRuntimeError.capabilityUnavailable(.mcpClient)
    }
    return try permitted.map { server in
      switch server.transport {
      case .stdio:
        guard let command = server.command, AgentPathSemantics.isAbsolute(command) else {
          throw AgentRuntimeError.invalidRequest("mcp.command")
        }
        return .object([
          "name": .string(server.name), "command": .string(command),
          "args": .array(server.args.map(ACPJSONValue.string)),
          "env": namedValues(server.environment),
        ])
      case .http:
        guard let url = server.url else { throw AgentRuntimeError.invalidRequest("mcp.url") }
        return .object([
          "type": .string("http"), "name": .string(server.name), "url": .string(url),
          "headers": namedValues(server.headers),
        ])
      }
    }
  }

  private static func namedValues(_ values: [String: String]) -> ACPJSONValue {
    .array(
      values.keys.sorted().map { name in
        .object(["name": .string(name), "value": .string(values[name]!)])
      })
  }
}

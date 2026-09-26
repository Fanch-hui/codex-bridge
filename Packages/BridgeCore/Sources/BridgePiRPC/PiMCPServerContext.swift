import BridgeAgentCore
import Foundation

enum PiMCPServerContext {
  private static let maximumServers = 64
  private static let maximumEncodedBytes = 24 * 1_024

  static func values(_ servers: [AgentMCPServerConfiguration]) throws -> [PiJSONValue] {
    guard servers.count <= maximumServers,
      Set(servers.map(\.id)).count == servers.count,
      servers.allSatisfy(valid)
    else { throw PiRPCError.invalidArgument("pi.mcp_configuration") }
    let values = servers.map { server in
      PiJSONValue.object([
        "id": .string(server.id), "name": .string(server.name),
        "transport": .string(server.transport.rawValue),
        "command": server.command.map(PiJSONValue.string) ?? .null,
        "args": .array(server.args.map(PiJSONValue.string)),
        "url": server.url.map(PiJSONValue.string) ?? .null,
        "environment": .object(server.environment.mapValues(PiJSONValue.string)),
        "headers": .object(server.headers.mapValues(PiJSONValue.string)),
      ])
    }
    guard try PiJSONValue.array(values).encoded().count <= maximumEncodedBytes else {
      throw PiRPCError.invalidArgument("pi.mcp_configuration_size")
    }
    return values
  }

  private static func valid(_ server: AgentMCPServerConfiguration) -> Bool {
    guard validText(server.id, maximumBytes: 256), validText(server.name, maximumBytes: 256),
      server.args.count <= 128, server.args.allSatisfy({ validText($0, maximumBytes: 8 * 1_024) }),
      validMap(server.environment), validMap(server.headers)
    else { return false }
    switch server.transport {
    case .stdio:
      return server.command.map { validText($0, maximumBytes: 4 * 1_024) } ?? false
    case .http:
      guard let value = server.url, let components = URLComponents(string: value),
        let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
        components.host != nil
      else { return false }
      return value.utf8.count <= 4 * 1_024 && !value.contains("\0")
    }
  }

  private static func validMap(_ values: [String: String]) -> Bool {
    values.count <= 128
      && values.allSatisfy {
        validText($0.key, maximumBytes: 256) && validText($0.value, maximumBytes: 8 * 1_024)
      }
  }

  private static func validText(_ value: String, maximumBytes: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximumBytes && !value.contains("\0")
  }
}

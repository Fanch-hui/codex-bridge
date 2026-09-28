import BridgeAgentCore
import BridgeServiceCore

public typealias ServiceAgentMCPScope = AgentMCPScope

extension AgentMCPScope {
  var settingsKey: ServiceSettingKey {
    switch self {
    case .deepSeekHarness: .deepSeekHarnessMCPServers
    case .pi: .piMCPServers
    case .qoderCN: .qoderCNMCPServers
    case .qoderInternational: .qoderInternationalMCPServers
    }
  }

  var secretNamespace: String {
    self == .deepSeekHarness ? "dsh-mcp" : "agent-mcp." + rawValue
  }
}

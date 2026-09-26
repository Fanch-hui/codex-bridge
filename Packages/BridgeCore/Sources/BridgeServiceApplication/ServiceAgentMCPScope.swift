import BridgeServiceCore

public enum ServiceAgentMCPScope: String, CaseIterable, Sendable {
  case deepSeekHarness = "deepseek-harness"
  case pi
  case qoderCN = "qoder.cn"
  case qoderInternational = "qoder.international"

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

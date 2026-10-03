import BridgeAgentCore

public typealias BridgeDesktopAgentMCPScope = AgentMCPScope

extension AgentMCPScope {
  public var displayName: String {
    switch self {
    case .deepSeekHarness: "DeepSeek Harness"
    case .pi: "Pi"
    case .qoderCN: "Qoder 中国版"
    case .qoderInternational: "Qoder 国际版"
    }
  }

  public var choice: BridgeDesktopChoice {
    BridgeDesktopChoice(id: rawValue, title: displayName)
  }
}

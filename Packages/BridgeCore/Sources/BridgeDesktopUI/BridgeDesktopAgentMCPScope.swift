import Foundation

public enum BridgeDesktopAgentMCPScope: String, CaseIterable, Codable, Sendable {
  case deepSeekHarness = "deepseek-harness"
  case pi
  case qoderCN = "qoder.cn"
  case qoderInternational = "qoder.international"

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

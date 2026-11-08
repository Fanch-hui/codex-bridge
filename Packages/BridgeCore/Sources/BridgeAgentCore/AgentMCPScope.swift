public enum AgentMCPScope: String, CaseIterable, Codable, Sendable {
  case deepSeekHarness = "deepseek-harness"
  case pi
  case claudeCode = "claude-code"
  case qoderCN = "qoder.cn"
  case qoderInternational = "qoder.international"
}

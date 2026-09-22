import BridgeIPC

/// Candidate presentation only. The service validates the actual target before submission.
public enum TaskHandoffSummary {
  public static func providers(
    excluding providerID: String, installations: [IPCAgentInstallationSummary]
  ) -> [(id: String, name: String)] {
    var result: [(id: String, name: String)] = providerID == "codex" ? [] : [("codex", "Codex")]
    for installation in installations
    where installation.isEnabled && installation.availability == "available"
      && installation.providerID != providerID
    {
      guard !result.contains(where: { $0.id == installation.providerID }) else { continue }
      let names = [
        "opencode": "OpenCode", "deepseek-harness": "DeepSeek Harness",
        "antigravity": "Antigravity",
      ]
      result.append(
        (installation.providerID, names[installation.providerID] ?? installation.displayName))
    }
    return result
  }
}

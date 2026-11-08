import Foundation

struct OpenCodeACPSingleAgentPolicy: Sendable {
  let modeID = "bridge-single-" + UUID().uuidString.lowercased()
  let majorVersion: Int

  init?(version: String?) {
    guard let version, let parsed = OpenCodeACPSemanticVersion(version),
      [1, 2].contains(parsed.major)
    else { return nil }
    majorVersion = parsed.major
  }

  func configuration() throws -> String {
    let agent: [String: Any]
    let configuration: [String: Any]
    if majorVersion == 1 {
      agent = [
        "mode": "primary", "description": "Project execution",
        "permission": ["task": "deny"], "tools": ["task": false],
      ]
      configuration = ["agent": [modeID: agent]]
    } else {
      agent = [
        "mode": "primary", "description": "Project execution",
        "permissions": [["action": "subagent", "resource": "*", "effect": "deny"]],
      ]
      configuration = [
        "agents": [modeID: agent],
        "policies": [["action": "tool.use", "resource": "subagent:*", "effect": "deny"]],
      ]
    }
    return String(
      decoding: try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys]),
      as: UTF8.self)
  }
}

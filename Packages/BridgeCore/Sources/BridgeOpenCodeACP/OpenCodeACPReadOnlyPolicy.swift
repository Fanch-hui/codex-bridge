import Foundation

struct OpenCodeACPReadOnlyPolicy: Sendable {
  let modeID = "bridge-readonly-" + UUID().uuidString.lowercased()

  func configuration() throws -> String {
    // Agent rules follow user rules in native evaluation. A unique agent keeps
    // deep-merged user or Plan tool overrides out of this final ruleset.
    let permissions: [String: Any] = [
      "*": "deny",
      "read": ["*": "allow", "*.env": "deny", "*.env.*": "deny"],
      "glob": "allow", "grep": "allow", "question": "allow",
    ]
    let configuration: [String: Any] = [
      "agent": [
        modeID: [
          "mode": "primary", "description": "Read-only project analysis",
          "permission": permissions,
        ]
      ]
    ]
    return String(
      decoding: try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys]),
      as: UTF8.self
    )
  }

  static func literalPrompt(_ text: String) -> String {
    // Native ACP dispatches leading slash text as commands before tool policy.
    "User request:\n" + text
  }
}

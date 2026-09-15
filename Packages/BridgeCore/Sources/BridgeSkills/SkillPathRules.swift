import BridgeAgentCore
import Foundation

enum SkillPathRules {
  static func isContained(_ candidate: URL, in root: URL) -> Bool {
    let candidatePath = candidate.standardizedFileURL.path
    let rootPath = root.standardizedFileURL.path
    #if os(Windows)
      return AgentPathSemantics.isContained(
        candidatePath,
        in: rootPath,
        style: .windows
      )
    #else
      return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    #endif
  }
}

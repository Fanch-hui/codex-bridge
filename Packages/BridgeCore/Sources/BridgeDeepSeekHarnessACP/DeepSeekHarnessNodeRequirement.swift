import Foundation

public struct DeepSeekHarnessNodeRequirement: Sendable {
  private enum Alternative: Sendable {
    case minimum(DeepSeekHarnessACPArtifactRuntime.SemanticVersion)
    case compatibleMajor(DeepSeekHarnessACPArtifactRuntime.SemanticVersion)
  }

  public let value: String
  private let alternatives: [Alternative]

  public init?(_ declared: String?) {
    let value = declared ?? DeepSeekHarnessACPConstants.nodeRequirement
    guard !value.isEmpty, value.utf8.count <= 256, !value.contains("\0") else { return nil }
    let parts = value.components(separatedBy: "||")
    var alternatives: [Alternative] = []
    for part in parts {
      let range = part.trimmingCharacters(in: .whitespacesAndNewlines)
      if range.hasPrefix(">="),
        let version = DeepSeekHarnessACPArtifactRuntime.SemanticVersion(String(range.dropFirst(2)))
      {
        alternatives.append(.minimum(version))
      } else if range.hasPrefix("^"),
        let version = DeepSeekHarnessACPArtifactRuntime.SemanticVersion(String(range.dropFirst())),
        version.major > 0
      {
        alternatives.append(.compatibleMajor(version))
      } else {
        return nil
      }
    }
    self.value = value
    self.alternatives = alternatives
  }

  public func accepts(_ nodeVersion: String) -> Bool {
    guard let version = DeepSeekHarnessACPArtifactRuntime.SemanticVersion(nodeVersion) else {
      return false
    }
    return alternatives.contains { alternative in
      switch alternative {
      case .minimum(let minimum): return version >= minimum
      case .compatibleMajor(let minimum):
        return version.major == minimum.major && version >= minimum
      }
    }
  }

  func incompatibility(_ version: String) -> DeepSeekHarnessACPError {
    if value == DeepSeekHarnessACPConstants.nodeRequirement {
      return .nodeVersionIncompatible(version)
    }
    return .nodeRequirementIncompatible(version: version, required: value)
  }
}

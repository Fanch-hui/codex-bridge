import Foundation

public enum AgentSelectedSkillSource: String, Codable, Sendable {
  case project
  case global
}

public struct AgentSelectedSkillFile: Codable, Equatable, Sendable {
  public let relativePath: String
  public let content: String

  public init(relativePath: String, content: String) throws {
    guard AgentPathSemantics.relativeComponents(relativePath, style: .posix) != nil,
      relativePath.utf8.count <= 1_024, content.utf8.count <= 64 * 1_024,
      !content.contains("\0")
    else {
      throw AgentRuntimeError.invalidRequest("skill.file")
    }
    self.relativePath = relativePath
    self.content = content
  }
}

/// An immutable snapshot of a Bridge Skill selected for one task.
public struct AgentSelectedSkill: Codable, Equatable, Sendable {
  public let name: String
  public let source: AgentSelectedSkillSource
  public let contentVersion: String
  public let files: [AgentSelectedSkillFile]

  public init(
    name: String,
    source: AgentSelectedSkillSource,
    contentVersion: String,
    files: [AgentSelectedSkillFile]
  ) throws {
    try AgentValidation.identifier(name, field: "skill.name", maximumBytes: 128)
    guard contentVersion.utf8.count == 64,
      contentVersion.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      !files.isEmpty, files.count <= 64,
      files.contains(where: { $0.relativePath == "SKILL.md" }),
      Set(files.map(\.relativePath)).count == files.count,
      files.reduce(0, { $0 + $1.content.utf8.count }) <= 512 * 1_024
    else {
      throw AgentRuntimeError.invalidRequest("skill.snapshot")
    }
    self.name = name
    self.source = source
    self.contentVersion = contentVersion
    self.files = files
  }
}

import Foundation

public struct MCPDirectCommandSummary: Codable, Equatable, Sendable {
  public let sessionID: String
  public let projectID: String
  public let status: String
  public let exitCode: Int32?
  public let startedAt: String
  public let endedAt: String?
  public let timedOut: Bool
  public let argv: [String]
  public let workingDirectory: String?

  public init(
    sessionID: String,
    projectID: String,
    status: String,
    exitCode: Int32?,
    startedAt: String,
    endedAt: String?,
    timedOut: Bool,
    argv: [String],
    workingDirectory: String?
  ) {
    self.sessionID = sessionID
    self.projectID = projectID
    self.status = status
    self.exitCode = exitCode
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.timedOut = timedOut
    self.argv = argv
    self.workingDirectory = workingDirectory
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case projectID = "project_id"
    case status
    case exitCode = "exit_code"
    case startedAt = "started_at"
    case endedAt = "ended_at"
    case timedOut = "timed_out"
    case argv
    case workingDirectory = "working_directory"
  }
}

public struct MCPDirectCommandPage: Codable, Equatable, Sendable {
  public let commands: [MCPDirectCommandSummary]

  public init(commands: [MCPDirectCommandSummary]) {
    self.commands = commands
  }

  private enum CodingKeys: String, CodingKey {
    case commands
  }
}

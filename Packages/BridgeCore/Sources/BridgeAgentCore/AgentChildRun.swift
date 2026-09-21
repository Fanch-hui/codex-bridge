import Foundation

/// A provider-observed child execution. Values are optional where a provider
/// does not expose that part of its native event; the presentation must never
/// invent a child result.
public struct AgentChildRun: Codable, Equatable, Sendable {
  public let id: String
  public let sessionID: String?
  public let name: String?
  public let status: String?
  public let summary: String?
  public let workspaceURLs: [String]

  public init(
    id: String,
    sessionID: String? = nil,
    name: String? = nil,
    status: String? = nil,
    summary: String? = nil,
    workspaceURLs: [String] = []
  ) throws {
    try AgentValidation.identifier(id, field: "childRun.id", maximumBytes: 1_024)
    try AgentValidation.optionalIdentifier(
      sessionID,
      field: "childRun.sessionID",
      maximumBytes: 1_024
    )
    try AgentValidation.optionalText(name, field: "childRun.name", maximumBytes: 512)
    try AgentValidation.optionalText(status, field: "childRun.status", maximumBytes: 128)
    try AgentValidation.optionalText(summary, field: "childRun.summary", maximumBytes: 4 * 1_024)
    guard workspaceURLs.count <= 32 else {
      throw AgentRuntimeError.invalidRequest("childRun.workspaceURLs")
    }
    for workspaceURL in workspaceURLs {
      try AgentValidation.optionalText(
        workspaceURL,
        field: "childRun.workspaceURL",
        maximumBytes: 4 * 1_024
      )
    }
    self.id = id
    self.sessionID = sessionID
    self.name = name
    self.status = status
    self.summary = summary
    self.workspaceURLs = workspaceURLs
  }
}

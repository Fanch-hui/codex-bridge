import Foundation

public struct AgentWorkspaceIsolation: Equatable, Sendable {
  public let runtimeDirectory: String

  public init(runtimeDirectory: String) throws {
    try AgentValidation.absolutePath(runtimeDirectory, field: "workspaceIsolation.runtimeDirectory")
    self.runtimeDirectory = runtimeDirectory
  }
}

public struct AgentWorkspaceIsolationReadiness: Equatable, Sendable {
  public let ready: Bool
  public let reason: String?

  public init(ready: Bool, reason: String? = nil) {
    self.ready = ready
    self.reason = reason
  }
}

/// Implemented only by providers that can verify their actual isolated launch.
public protocol AgentWorkspaceIsolationProviding: AgentProvider {
  func isolatedWorkspaceReadiness(
    installation: AgentInstallation, workspaceRoot: String, runtimeDirectory: String
  ) async throws -> AgentWorkspaceIsolationReadiness
}

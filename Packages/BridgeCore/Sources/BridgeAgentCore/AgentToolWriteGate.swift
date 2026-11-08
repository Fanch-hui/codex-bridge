import Foundation

/// Per-tool-call project write admission for an Agent task that shares the project directory
/// with other writers (the workbench root session, its native subagents and other external
/// Agents). The provider calls `acquire` before a writing tool runs and `release` once that
/// tool has finished, so concurrent Agents queue only around individual writes.
///
/// `acquire` waits until the lease is granted; it is reentrant for the same tool call and throws
/// when the task is cancelled or the workspace cannot accept writes. `release` is idempotent and
/// ignores unknown tool calls. The service releases any lease still held when the task ends.
public struct AgentToolWriteGate: Sendable {
  public let id: String
  private let acquireLease: @Sendable (String) async throws -> Void
  private let releaseLease: @Sendable (String) async -> Void

  public init(
    id: String = UUID().uuidString.lowercased(),
    acquire: @escaping @Sendable (_ toolCallID: String) async throws -> Void,
    release: @escaping @Sendable (_ toolCallID: String) async -> Void
  ) {
    self.id = id
    self.acquireLease = acquire
    self.releaseLease = release
  }

  public func acquire(toolCallID: String) async throws {
    try AgentValidation.identifier(toolCallID, field: "toolWriteGate.toolCallID", maximumBytes: 512)
    try await acquireLease(toolCallID)
  }

  public func release(toolCallID: String) async {
    guard
      (try? AgentValidation.identifier(
        toolCallID, field: "toolWriteGate.toolCallID", maximumBytes: 512)) != nil
    else { return }
    await releaseLease(toolCallID)
  }
}

extension AgentToolWriteGate: Equatable {
  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

extension AgentToolWriteGate {
  /// Providers whose tool hooks enforce the gate. Shared-directory tasks of other providers keep
  /// holding the project write lease for the whole task.
  public static let supportedProviders: Set<AgentProviderID> = [.claudeCode, .qoder, .pi]
}

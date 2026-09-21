import BridgeDirectCommand
import BridgeDomain
import BridgeMCP
import BridgeSecurity
import Foundation

extension BridgeServiceApplication {
  public func serviceDirectReadCommand(
    sessionID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandOutput {
    try await serviceDirectReadCommand(sessionID: sessionID, cursor: nil, deadline: deadline)
  }

  public func serviceDirectReadCommand(
    sessionID: String,
    cursor: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandOutput {
    try Self.checkDeadline(deadline)
    guard !sessionID.isEmpty, sessionID.utf8.count <= 128 else {
      throw BridgeMCPQueryError.commandSessionNotFound
    }
    guard let cursorOffset = Self.decodeCommandCursor(cursor) else {
      throw BridgeMCPQueryError.contractRejected
    }
    if let cursorOffset {
      guard let current = await directCommands.output(sessionID: sessionID, from: cursorOffset)
      else { throw BridgeMCPQueryError.commandSessionNotFound }
      return Self.output(current.session, delta: current.delta)
    }
    guard let session = await directCommands.snapshot(sessionID: sessionID) else {
      throw BridgeMCPQueryError.commandSessionNotFound
    }
    return Self.output(session)
  }

  public func serviceListDirectCommands(
    projectID: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandPage {
    try Self.checkDeadline(deadline)
    guard (1...100).contains(limit) else {
      throw BridgeMCPQueryError.contractRejected
    }
    let filter: ProjectID?
    if let projectID {
      guard !projectID.isEmpty, projectID.utf8.count <= 128 else {
        throw BridgeMCPQueryError.contractRejected
      }
      filter = ProjectID(rawValue: projectID)
    } else {
      filter = nil
    }
    let sessions = await directCommands.recentSessions(projectID: filter, limit: limit)
    return MCPDirectCommandPage(
      commands: sessions.map { session in
        MCPDirectCommandSummary(
          sessionID: session.sessionID,
          projectID: session.projectID.rawValue,
          status: session.status,
          exitCode: session.exitCode,
          startedAt: iso8601.string(from: session.startedAt),
          endedAt: session.endedAt.map { iso8601.string(from: $0) },
          timedOut: session.timedOut,
          argv: OutboundContentSecurity.redactedCommandArguments(
            session.argv,
            maximumArguments: 32,
            maximumArgumentUTF8Bytes: 512
          ),
          workingDirectory: session.workingDirectory.map {
            OutboundContentSecurity.redactedCommand($0, maximumUTF8Bytes: 1_024)
          }
        )
      }
    )
  }

  public func serviceDirectWriteStdin(
    sessionID: String,
    data: String,
    deadline: ContinuousClock.Instant
  ) async throws {
    try await serviceDirectWriteStdin(
      sessionID: sessionID,
      data: data,
      closeStdin: false,
      deadline: deadline
    )
  }

  public func serviceDirectWriteStdin(
    sessionID: String,
    data: String,
    closeStdin: Bool,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    guard !sessionID.isEmpty, sessionID.utf8.count <= 128 else {
      throw BridgeMCPQueryError.commandSessionNotFound
    }
    guard !data.isEmpty || closeStdin, data.utf8.count <= 64 * 1_024 else {
      throw BridgeMCPQueryError.contractRejected
    }
    do {
      try await directCommands.writeStdin(
        sessionID: sessionID,
        data: Data(data.utf8),
        closeStdin: closeStdin
      )
    } catch {
      throw Self.publicCommandError(error)
    }
  }

  public func serviceDirectInterruptCommand(
    sessionID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandOutput {
    try Self.checkDeadline(deadline)
    guard !sessionID.isEmpty, sessionID.utf8.count <= 128 else {
      throw BridgeMCPQueryError.commandSessionNotFound
    }
    guard let existing = await directCommands.snapshot(sessionID: sessionID) else {
      throw BridgeMCPQueryError.commandSessionNotFound
    }
    if existing.status != "running" {
      return Self.output(existing)
    }
    do {
      try await directCommands.interrupt(sessionID: sessionID)
    } catch {
      throw Self.publicCommandError(error)
    }
    guard let session = await directCommands.snapshot(sessionID: sessionID) else {
      throw BridgeMCPQueryError.commandSessionNotFound
    }
    return Self.output(session)
  }

  static func output(_ session: DirectCommandSession) -> MCPDirectCommandOutput {
    output(session, delta: nil)
  }

  static func output(
    _ session: DirectCommandSession,
    delta: DirectCommandOutputDelta?
  ) -> MCPDirectCommandOutput {
    MCPDirectCommandOutput(
      sessionID: session.sessionID,
      status: session.status,
      exitCode: session.exitCode.map(Int.init),
      timedOut: session.timedOut,
      commandStatus: session.status,
      commandTimedOut: session.timedOut,
      readTimeout: false,
      head: delta == nil
        ? OutboundContentSecurity.redactedCommandOutput(
          session.output.head, maximumUTF8Bytes: 16 * 1_024) : "",
      tail: delta == nil
        ? OutboundContentSecurity.redactedCommandOutput(
          session.output.tail, maximumUTF8Bytes: 64 * 1_024) : "",
      byteCount: session.output.byteCount,
      truncated: session.output.truncated,
      output: delta.map {
        OutboundContentSecurity.redactedCommandContinuation(
          context: $0.redactionContext, delta: $0.text, maximumUTF8Bytes: 64 * 1024)
      },
      currentOffset: delta?.currentOffset,
      nextCursor: delta.map { encodeCommandCursor($0.nextOffset) },
      eof: delta.map { session.status != "running" && $0.reachedEnd },
      outputTruncated: delta?.truncated,
      executionEnvironment: Self.mcpEnvironment(session.executionEnvironment)
    )
  }

  private static func encodeCommandCursor(_ offset: Int) -> String {
    "v1.\(max(0, offset))"
  }

  private static func decodeCommandCursor(_ value: String?) -> Int?? {
    guard let value else { return .some(nil) }
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0] == "v1", let offset = Int(parts[1]), offset >= 0 else {
      return nil
    }
    return .some(offset)
  }

  private static func mcpEnvironment(
    _ environment: DirectCommandExecutionEnvironment
  ) -> MCPExecutionEnvironment {
    MCPExecutionEnvironment(
      bridgeSandbox: environment.bridgeSandbox,
      scope: "direct_command",
      sandboxExec: environment.sandboxExec,
      nestedSandbox: environment.nestedSandbox,
      loopback: environment.loopback,
      childNetworkPolicy: environment.childNetworkPolicy,
      xcodebuildNestedSandbox: environment.xcodebuildNestedSandbox,
      loopbackBind: environment.loopbackBind,
      limitations: environment.limitations
    )
  }
}

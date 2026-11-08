import BridgeCodexRPC
import BridgeDomain
import BridgeServiceCore
import Foundation

public actor ExecutionManager {
  private let configuration: ExecutionManagerConfiguration
  private var sessions: [TaskID: ExecutionSession] = [:]
  private var stopping: [TaskID: Task<Void, Never>] = [:]

  public init(configuration: ExecutionManagerConfiguration) {
    self.configuration = configuration
  }

  package func codexInstallationArtifacts() throws -> [ServiceAgentExecutableIdentity] {
    let launch = configuration.appServer.current()
    var identities = [try ServiceAgentExecutableIdentity(capturing: launch.executableURL.path)]
    #if os(Windows)
      if launch.arguments.count >= 4,
        Array(launch.arguments.prefix(3)) == ["/d", "/s", "/c"]
      {
        let commandPath = launch.arguments[3]
        if commandPath.lowercased().hasSuffix(".cmd")
          || commandPath.lowercased().hasSuffix(".bat")
        {
          identities.append(try ServiceAgentExecutableIdentity(capturing: commandPath))
        }
      }
    #endif
    return identities
  }

  public func start(_ request: ExecutionRequest) async throws -> ExecutionHandle {
    let taskID = request.task.id
    guard sessions[taskID] == nil, stopping[taskID] == nil else {
      throw ExecutionServiceError.activeSession(taskID)
    }
    guard sessions.count + stopping.count < configuration.maximumConcurrentSessions else {
      throw ExecutionServiceError.sessionLimitReached
    }

    let appServer = try Self.launchConfiguration(request, configuration: configuration)
    let session = ExecutionSession(
      taskID: taskID,
      configuration: configuration,
      appServer: appServer,
      projectRoot: request.executionRootPath,
      approvalLimits: ExecutionApprovalLimits(request: request),
      onTermination: { [weak self] taskID, session in
        await self?.remove(taskID: taskID, matching: session)
      }
    )
    sessions[taskID] = session
    do {
      let binding = try await session.start(request)
      guard sessions[taskID] === session else {
        throw ExecutionServiceError.sessionUnavailable(taskID)
      }
      return ExecutionHandle(taskID: taskID, binding: binding, events: session.events)
    } catch {
      if sessions[taskID] === session {
        sessions[taskID] = nil
      }
      await session.shutdown()
      throw error
    }
  }

  private static func launchConfiguration(
    _ request: ExecutionRequest,
    configuration: ExecutionManagerConfiguration
  ) throws -> AppServerConfiguration {
    let launch = configuration.appServer.current()
    let base = request.nativeSubagentsAllowed ? launch : launch.disablingNativeSubagents()
    guard let workspace = request.isolatedWorkspace else { return base }
    do {
      try request.project.root.validateCurrentIdentity()
      try workspace.root.validateCurrentIdentity()
      try workspace.runtimeRoot.validateCurrentIdentity()
      let isolated = try CodexIsolatedLaunch.prepare(
        configuration: base,
        workspaceRoot: URL(fileURLWithPath: workspace.root.canonicalPath),
        runtimeDirectory: URL(fileURLWithPath: workspace.runtimeRoot.canonicalPath)
      )
      try workspace.root.validateCurrentIdentity()
      try workspace.runtimeRoot.validateCurrentIdentity()
      return isolated
    } catch {
      throw ExecutionServiceError.invalidRequest("isolatedWorkspace.confinement")
    }
  }

  public func steer(
    taskID: TaskID,
    expectedTurnID: String,
    text: String
  ) async throws {
    let session = try requiredSession(taskID)
    try await session.steer(expectedTurnID: expectedTurnID, text: text)
  }

  public func interrupt(
    taskID: TaskID,
    expectedTurnID: String? = nil
  ) async throws {
    let session = try requiredSession(taskID)
    try await session.interrupt(expectedTurnID: expectedTurnID)
  }

  public func pendingApprovals(taskID: TaskID? = nil) async -> [ExecutionApprovalRequest] {
    if let taskID {
      guard let session = sessions[taskID] else { return [] }
      return await session.pendingApprovalRequests()
    }
    var result: [ExecutionApprovalRequest] = []
    for session in sessions.values {
      result.append(contentsOf: await session.pendingApprovalRequests())
    }
    return result.sorted { lhs, rhs in
      lhs.taskID.rawValue == rhs.taskID.rawValue
        ? lhs.id < rhs.id
        : lhs.taskID.rawValue < rhs.taskID.rawValue
    }
  }

  public func respondToApproval(
    taskID: TaskID,
    approvalID: String,
    decision: LocalApprovalDecision,
    answers: [String: [String]]? = nil
  ) async throws {
    let session = try requiredSession(taskID)
    try await session.respondToApproval(
      id: approvalID,
      decision: decision,
      answers: answers
    )
  }

  public func finalizeApproval(
    taskID: TaskID,
    approvalID: String,
    committed: Bool
  ) async {
    guard let session = sessions[taskID] else { return }
    await session.finalizeApproval(id: approvalID, committed: committed)
  }

  public func stop(taskID: TaskID) async {
    if let pending = stopping[taskID] {
      await pending.value
      return
    }
    guard let session = sessions.removeValue(forKey: taskID) else { return }
    let pending = Task { await session.shutdown() }
    stopping[taskID] = pending
    await pending.value
    stopping.removeValue(forKey: taskID)
  }

  public func shutdown() async {
    let active = Array(sessions.keys)
    for taskID in active { await stop(taskID: taskID) }
    for pending in Array(stopping.values) { await pending.value }
  }

  public func hasActiveSession(taskID: TaskID) -> Bool {
    sessions[taskID] != nil || stopping[taskID] != nil
  }

  private func requiredSession(_ taskID: TaskID) throws -> ExecutionSession {
    guard let session = sessions[taskID] else {
      throw ExecutionServiceError.sessionUnavailable(taskID)
    }
    return session
  }

  private func remove(taskID: TaskID, matching session: ExecutionSession) {
    if sessions[taskID] === session {
      sessions[taskID] = nil
    }
  }
}

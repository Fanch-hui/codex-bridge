import BridgeAgentCore
import BridgeDomain
import Foundation

/// Engine operations behind a tool write lease. `cancel` revokes an owner for good: it removes a
/// queued request and releases a lease whose grant receipt was lost.
struct EmbeddedDSHToolWriteEngine: Sendable {
  let acquire: @Sendable (_ rootID: String, _ owner: String) async throws -> String
  let release: @Sendable (_ rootID: String, _ owner: String, _ token: String) async throws -> Void
  let cancel: @Sendable (_ rootID: String, _ owner: String) async throws -> Void
}

enum EmbeddedDSHToolWriteError: Error, Equatable {
  case gateClosed
}

/// Per-task record of the project write leases a workbench child holds around its writing tool
/// calls. Each acquisition uses a fresh engine owner because a revoked owner can never be reused.
actor EmbeddedDSHToolWriteLeases {
  private struct Lease {
    let owner: String
    let token: String
  }

  private struct Session {
    let generation: UInt64
    let rootID: String
    let childID: String
    let engine: EmbeddedDSHToolWriteEngine
    var held: [String: Lease] = [:]
    var acquiring: [String: Task<Void, Error>] = [:]
  }

  private var sessions: [TaskID: Session] = [:]
  private var generation: UInt64 = 0
  private var attempts: UInt64 = 0
  private let report: @Sendable (String) -> Void

  init(
    report: @escaping @Sendable (String) -> Void = EmbeddedDSHToolWriteLeases.writeToStandardError
  ) {
    self.report = report
  }

  /// Starts the lease session of a task run, replacing any left over from an earlier run.
  func makeGate(
    taskID: TaskID, rootID: String, childID: String, engine: EmbeddedDSHToolWriteEngine
  ) async -> AgentToolWriteGate {
    await releaseAll(taskID: taskID)
    generation &+= 1
    let generation = generation
    sessions[taskID] = Session(
      generation: generation, rootID: rootID, childID: childID, engine: engine)
    return AgentToolWriteGate(
      id: "\(taskID.rawValue):\(generation)",
      acquire: { [self] toolCallID in
        try await self.acquire(taskID: taskID, generation: generation, toolCallID: toolCallID)
      },
      release: { [self] toolCallID in
        await self.release(taskID: taskID, generation: generation, toolCallID: toolCallID)
      })
  }

  /// Ends the task's session: queued requests are revoked and held leases are released.
  func releaseAll(taskID: TaskID) async {
    guard let session = sessions.removeValue(forKey: taskID) else { return }
    let requests = Array(session.acquiring.values)
    for request in requests { request.cancel() }
    for request in requests { _ = await request.result }
    for lease in session.held.values {
      await releaseLease(lease, rootID: session.rootID, engine: session.engine)
    }
  }

  func closeAll() async {
    for taskID in Array(sessions.keys) { await releaseAll(taskID: taskID) }
  }

  private func acquire(taskID: TaskID, generation: UInt64, toolCallID: String) async throws {
    try Task.checkCancellation()
    guard let session = sessions[taskID], session.generation == generation else {
      throw EmbeddedDSHToolWriteError.gateClosed
    }
    if session.held[toolCallID] != nil { return }
    let request: Task<Void, Error>
    if let queued = session.acquiring[toolCallID] {
      request = queued
    } else {
      attempts &+= 1
      let owner = Self.owner(
        childID: session.childID, taskID: taskID, attempt: attempts, toolCallID: toolCallID)
      request = Task {
        try await self.requestLease(
          taskID: taskID, generation: generation, toolCallID: toolCallID, owner: owner)
      }
      sessions[taskID]?.acquiring[toolCallID] = request
    }
    try await withTaskCancellationHandler {
      try await request.value
    } onCancel: {
      request.cancel()
    }
  }

  private func requestLease(
    taskID: TaskID, generation: UInt64, toolCallID: String, owner: String
  ) async throws {
    guard let session = sessions[taskID], session.generation == generation else {
      throw EmbeddedDSHToolWriteError.gateClosed
    }
    defer {
      if sessions[taskID]?.generation == generation {
        sessions[taskID]?.acquiring[toolCallID] = nil
      }
    }
    do {
      let token = try await session.engine.acquire(session.rootID, owner)
      try Task.checkCancellation()
      guard sessions[taskID]?.generation == generation else {
        throw EmbeddedDSHToolWriteError.gateClosed
      }
      sessions[taskID]?.held[toolCallID] = Lease(owner: owner, token: token)
    } catch {
      await cancelOwner(owner, rootID: session.rootID, engine: session.engine)
      throw error
    }
  }

  private func release(taskID: TaskID, generation: UInt64, toolCallID: String) async {
    guard let session = sessions[taskID], session.generation == generation else { return }
    if let request = session.acquiring[toolCallID] {
      request.cancel()
      _ = await request.result
    }
    guard let lease = sessions[taskID]?.held.removeValue(forKey: toolCallID) else { return }
    await releaseLease(lease, rootID: session.rootID, engine: session.engine)
  }

  private func releaseLease(
    _ lease: Lease, rootID: String, engine: EmbeddedDSHToolWriteEngine
  ) async {
    do {
      try await engine.release(rootID, lease.owner, lease.token)
    } catch {
      await cancelOwner(lease.owner, rootID: rootID, engine: engine)
    }
  }

  private func cancelOwner(
    _ owner: String, rootID: String, engine: EmbeddedDSHToolWriteEngine
  ) async {
    do {
      try await engine.cancel(rootID, owner)
    } catch {
      report("Workbench tool write lease could not be revoked: \(error)")
    }
  }

  /// Engine owner IDs are limited to 1,024 bytes; the identity is hashed when it would not fit.
  static func owner(childID: String, taskID: TaskID, attempt: UInt64, toolCallID: String)
    -> String
  {
    let identity = "\(childID):\(taskID.rawValue):\(attempt):\(toolCallID)"
    let owner = "external-tool:" + identity
    guard owner.utf8.count <= 1_024 else {
      return "external-tool:" + ServiceEmbeddedDSHController.digest(identity)
    }
    return owner
  }

  static func writeToStandardError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
  }
}

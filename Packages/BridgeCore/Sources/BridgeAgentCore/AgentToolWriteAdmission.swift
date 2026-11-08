import Foundation

/// Takes the project write lease from a task's `AgentToolWriteGate` one tool call at a time, for
/// providers whose tool hooks run independently per call: the provider asks before a writing tool
/// runs and gives the lease back when the tool is finished, however it ended.
///
/// Acquiring waits for the gate in the background so the provider's event loop keeps running while
/// another Agent holds the project. The reply closure runs exactly once per accepted request,
/// unless the admission is closed first and nobody is waiting any more.
public actor AgentToolWriteAdmission {
  private struct Acquisition {
    let token: UUID
    let reply: @Sendable (Bool) async -> Void
    let task: Task<Void, Never>
  }

  private let gate: AgentToolWriteGate
  private var held = Set<String>()
  private var acquisitions: [String: Acquisition] = [:]
  private var closed = false

  public init(gate: AgentToolWriteGate) {
    self.gate = gate
  }

  /// Starts waiting for the lease of one tool call and answers `reply(granted)` once decided.
  /// A request that arrives after `close` is answered as not granted.
  public func acquire(
    _ toolCallID: String, reply: @escaping @Sendable (_ granted: Bool) async -> Void
  ) async throws {
    try AgentValidation.identifier(toolCallID, field: "toolWriteGate.toolCallID", maximumBytes: 512)
    guard acquisitions[toolCallID] == nil else {
      throw AgentRuntimeError.invalidRequest("toolWriteGate.duplicate_acquire")
    }
    guard !closed else {
      await reply(false)
      return
    }
    let token = UUID()
    let gate = gate
    let task = Task {
      let granted = (try? await gate.acquire(toolCallID: toolCallID)) != nil
      await self.settle(toolCallID, token: token, granted: granted)
    }
    acquisitions[toolCallID] = Acquisition(token: token, reply: reply, task: task)
  }

  /// Gives the lease back, or withdraws a request that is still waiting (it is answered as not
  /// granted). Unknown tool calls are ignored.
  public func release(_ toolCallID: String) async {
    if let acquisition = acquisitions.removeValue(forKey: toolCallID) {
      acquisition.task.cancel()
      await acquisition.reply(false)
    }
    held.remove(toolCallID)
    await gate.release(toolCallID: toolCallID)
  }

  /// Ends the admission. Held leases are given back only when every process of the execution is
  /// confirmed gone; otherwise they stay with the service, which keeps the project occupied.
  public func close(releasingHeld: Bool) async {
    closed = true
    for acquisition in acquisitions.values { acquisition.task.cancel() }
    acquisitions.removeAll()
    guard releasingHeld else { return }
    let ids = held
    held.removeAll()
    for id in ids { await gate.release(toolCallID: id) }
  }

  private func settle(_ toolCallID: String, token: UUID, granted: Bool) async {
    guard let acquisition = acquisitions[toolCallID], acquisition.token == token else {
      // Withdrawn or closed while waiting: nobody runs the tool, so a late grant is given back.
      if granted, acquisitions[toolCallID] == nil, !held.contains(toolCallID) {
        await gate.release(toolCallID: toolCallID)
      }
      return
    }
    acquisitions.removeValue(forKey: toolCallID)
    if granted { held.insert(toolCallID) }
    await acquisition.reply(granted)
  }
}

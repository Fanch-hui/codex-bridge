import BridgeAgentCore
import Foundation

/// Admits writing Pi tool calls through the task's `AgentToolWriteGate`.
///
/// Pi runs the `tool_call` hooks of one assistant message one after another before any of its
/// tools starts. A mutually exclusive gate must therefore not be asked again for a sibling call
/// while an earlier call of this task already holds it, or the earlier tool could never run. The
/// coordinator takes one gate lease for the first admitted call and keeps it until every admitted
/// call of this execution has ended (`tool_execution_end`), so the gate only sees acquire and
/// release for that first call.
actor PiToolWriteGateCoordinator {
  private let gate: AgentToolWriteGate
  private let client: PiRPCClient
  private var holder: String?
  private var active: Set<String> = []
  private var pending: [String: Task<Void, Never>] = [:]

  init(gate: AgentToolWriteGate, client: PiRPCClient) {
    self.gate = gate
    self.client = client
  }

  var isWaiting: Bool { !pending.isEmpty }

  /// Starts admission for one tool call and answers the extension's UI request once decided.
  /// A refused lease only rejects that tool call, as with the other providers; the model can retry.
  func admit(_ request: PiToolWriteGateRequest) throws {
    guard pending[request.toolCallID] == nil, !active.contains(request.toolCallID) else {
      throw PiRPCError.invalidRecord
    }
    pending[request.toolCallID] = Task { await run(request) }
  }

  /// Marks a tool call as finished and releases the lease once no admitted call remains. A call
  /// that ends while still waiting (blocked or aborted elsewhere) no longer needs admission.
  func toolEnded(_ toolCallID: String) async {
    pending[toolCallID]?.cancel()
    guard active.remove(toolCallID) != nil, active.isEmpty, let held = holder else { return }
    holder = nil
    await gate.release(toolCallID: held)
  }

  /// Cancels admissions that are still waiting; each one answers the extension as cancelled.
  func cancelPending() async {
    let tasks = Array(pending.values)
    for task in tasks { task.cancel() }
    for task in tasks { await task.value }
  }

  /// Ends the execution's participation: cancels waiting admissions and releases the lease.
  func releaseAll() async {
    await cancelPending()
    active.removeAll()
    guard let held = holder else { return }
    holder = nil
    await gate.release(toolCallID: held)
  }

  private func run(_ request: PiToolWriteGateRequest) async {
    defer { pending[request.toolCallID] = nil }
    do {
      try await lease(for: request.toolCallID)
      try Task.checkCancellation()
      try await client.answerUI(
        id: request.wireID, fields: ["value": .string(PiToolWriteGateRequest.grantedOption)])
    } catch {
      await toolEnded(request.toolCallID)
      // Unblocks the extension so that only this tool call is rejected.
      try? await client.answerUI(id: request.wireID, fields: ["cancelled": .bool(true)])
    }
  }

  private func lease(for toolCallID: String) async throws {
    if holder == nil {
      try await gate.acquire(toolCallID: toolCallID)
      if holder == nil {
        holder = toolCallID
      } else {
        await gate.release(toolCallID: toolCallID)
      }
    }
    active.insert(toolCallID)
  }
}

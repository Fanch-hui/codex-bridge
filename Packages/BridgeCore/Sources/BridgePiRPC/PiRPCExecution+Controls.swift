import BridgeAgentCore
import Foundation

extension PiRPCExecution {
  func sendInput(
    _ text: String, command: String, initial: Bool = false, images: [PiJSONValue] = []
  ) async throws {
    guard phase == .active else { throw AgentRuntimeError.processUnavailable }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf8.count <= 32 * 1_024, !text.contains("\0"),
      pendingInputs.count < 32, pendingInputBytes + text.utf8.count <= 256 * 1_024
    else { throw AgentRuntimeError.invalidRequest("pi.input") }
    inFlightInputs += 1
    settledObserved = false
    if !initial {
      pendingInputs.append(text)
      pendingInputBytes += text.utf8.count
    }
    defer {
      inFlightInputs -= 1
      scheduleSettlement()
    }
    do {
      var fields: [String: PiJSONValue] = ["message": .string(text)]
      if !images.isEmpty { fields["images"] = .array(images) }
      let result = try await client.request(command, fields: fields)
      guard let disposition = result.data?["disposition"]?.stringValue,
        disposition == "started" || disposition == "queued"
      else {
        throw PiRPCError.invalidArgument("pi_input_not_started")
      }
      try await waitForEvents(result.eventSequenceBarrier)
    } catch {
      await fail(error)
      throw error
    }
  }

  func steer(_ text: String) async throws { try await sendInput(text, command: "follow_up") }

  func resolveApproval(_ id: String, optionID: String) async throws {
    guard phase == .active, let pending = approvals[id], let option = pending.wireOptions[optionID]
    else {
      throw AgentRuntimeError.approvalUnavailable(id)
    }
    approvals.removeValue(forKey: id)
    do {
      try await client.answerUI(id: pending.wireID, fields: ["value": .string(option)])
      lastActivity = .now
    } catch {
      await fail(error)
      throw error
    }
  }

  func resolveUserInput(_ inputID: String, response: AgentUserInputResponse) async throws {
    guard phase == .active, let pending = userInputs[inputID] else {
      throw AgentRuntimeError.approvalUnavailable(inputID)
    }
    let fields = try pending.responseFields(for: response)
    userInputs.removeValue(forKey: inputID)
    do {
      try await client.answerUI(id: pending.wireID, fields: fields)
      lastActivity = .now
    } catch {
      await fail(error)
      throw error
    }
  }

  func interrupt() async throws {
    try await stopCurrent()
    await finish(.interrupted)
  }

  func interruptAndSteer(_ text: String) async throws {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf8.count <= 32 * 1_024, !text.contains("\0")
    else {
      throw AgentRuntimeError.invalidRequest("pi.input")
    }
    try await stopCurrent()
    guard phase == .stopping else { throw AgentRuntimeError.processUnavailable }
    phase = .active
    settledObserved = false
    try await sendInput(text, command: "prompt")
  }

  private func stopCurrent() async throws {
    guard phase == .active else { throw AgentRuntimeError.processUnavailable }
    phase = .stopping
    do {
      let deadline = ContinuousClock.now.advanced(by: .seconds(35))
      while inFlightInputs > 0 {
        guard phase == .stopping, ContinuousClock.now < deadline else { throw PiRPCError.timedOut }
        try await Task.sleep(for: .milliseconds(5))
      }
      let pending = approvals.values
      approvals.removeAll()
      for approval in pending {
        try await client.answerUI(id: approval.wireID, fields: ["cancelled": .bool(true)])
      }
      let inputs = Array(userInputs.values)
      userInputs.removeAll()
      for input in inputs {
        try await client.answerUI(id: input.wireID, fields: ["cancelled": .bool(true)])
      }
      _ = try await client.request("clear_queue")
      pendingInputs.removeAll()
      pendingInputBytes = 0
      let aborted = try await client.request("abort", timeout: .seconds(60))
      try await waitForEvents(aborted.eventSequenceBarrier)
      let state = try await client.request("get_state")
      try await waitForEvents(state.eventSequenceBarrier)
      guard phase == .stopping, state.data?["isStreaming"]?.boolValue == false,
        state.data?["isCompacting"]?.boolValue == false,
        state.data?["pendingMessageCount"]?.integerValue == 0,
        normalizer.activeToolCount == 0
      else { throw PiRPCError.invalidArgument("pi_abort_not_idle") }
    } catch {
      await fail(error)
      throw error
    }
  }
}

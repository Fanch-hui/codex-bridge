import BridgeAgentCore
import BridgeDomain
import Foundation

actor PiRPCExecution {
  nonisolated let events: AsyncThrowingStream<AgentEventEnvelope, any Error>
  let client: PiRPCClient
  let request: AgentExecutionRequest
  var initialImages: [PiJSONValue]
  let binding: AgentBinding
  let nonce: String
  let usageEnabled: Bool
  let selectedSkillStage: PiSelectedSkillStage?
  let continuation: AsyncThrowingStream<AgentEventEnvelope, any Error>.Continuation
  let initialSequence: Int64
  var normalizer = PiEventNormalizer()
  var consumedSequence: Int64
  var sequence: Int64 = 0
  var phase = Phase.active
  var inFlightInputs = 0
  var pendingInputs: [String] = []
  var pendingInputBytes = 0
  var initialInputSeen = false
  var settledObserved = false
  var settlementGeneration: Int64 = 0
  var approvals: [String: PiExtensionApproval] = [:]
  var userInputs: [String: PiExtensionUserInput] = [:]
  var reader: Task<Void, Never>?
  var settlement: Task<Void, Never>?
  var watchdog: Task<Void, Never>?
  var usageRefresh: Task<Void, Never>?
  var lastUsage: AgentUsageStatistics?
  var lastActivity = ContinuousClock.now

  enum Phase { case active, stopping, closing, closed }

  init(
    client: PiRPCClient, request: AgentExecutionRequest, binding: AgentBinding,
    nonce: String, initialSequence: Int64, usageEnabled: Bool,
    initialImages: [PiJSONValue] = [], selectedSkillStage: PiSelectedSkillStage? = nil
  ) {
    self.client = client
    self.request = request
    self.initialImages = initialImages
    self.binding = binding
    self.nonce = nonce
    self.usageEnabled = usageEnabled
    self.selectedSkillStage = selectedSkillStage
    self.initialSequence = initialSequence
    consumedSequence = initialSequence
    let stream = AsyncThrowingStream.makeStream(
      of: AgentEventEnvelope.self,
      throwing: (any Error).self, bufferingPolicy: .bufferingOldest(256))
    events = stream.stream
    continuation = stream.continuation
  }

  func start() {
    guard reader == nil else { return }
    let source = client.events
    reader = Task { [weak self] in
      do {
        for try await event in source {
          guard let self else { return }
          await self.consume(event)
        }
        await self?.streamEnded()
      } catch { await self?.fail(error) }
    }
    Task { [weak self] in
      guard let self else { return }
      await self.sendInitialPrompt()
    }
    watchdog = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(10)) } catch { return }
        await self?.checkActivity()
      }
    }
  }

  private func sendInitialPrompt() async {
    do {
      try await sendInput(request.prompt, command: "prompt", initial: true, images: initialImages)
      initialImages.removeAll(keepingCapacity: false)
    } catch {
      await fail(error)
    }
  }

  private func consume(_ event: PiRPCEvent) async {
    guard phase == .active || phase == .stopping else { return }
    guard event.sequence >= initialSequence else { return }
    consumedSequence = event.sequence + 1
    lastActivity = .now
    do {
      switch event.value["type"]?.stringValue {
      case "agent_start": settledObserved = false
      case "agent_settled":
        guard settlementGeneration < Int64.max else { throw PiRPCError.invalidRecord }
        settlementGeneration += 1
        settledObserved = true
        scheduleSettlement()
      case "extension_ui_request":
        try await handleUI(event.value)
        if let entries = try PiExtensionPlanBridge.plan(
          event.value, nonce: nonce, taskID: request.taskID
        ) {
          try emit(.plan(entries))
        }
      case "message_start": try observeUserInput(event.value)
      default: break
      }
      for normalized in try normalizer.normalize(event.value) { try emit(normalized) }
      if isAssistantMessageEnd(event.value) { scheduleUsageRefresh() }
    } catch { await fail(error) }
  }

  private func isAssistantMessageEnd(_ value: PiJSONValue) -> Bool {
    value["type"]?.stringValue == "message_end"
      && value["message"]?["role"]?.stringValue == "assistant"
  }

  private func scheduleUsageRefresh() {
    guard usageEnabled, phase == .active, usageRefresh == nil else { return }
    usageRefresh = Task { [weak self] in await self?.refreshUsage() }
  }

  func refreshUsage() async {
    defer { usageRefresh = nil }
    do {
      let response = try await client.request("get_session_stats", timeout: .seconds(10))
      guard phase == .active, let statistics = try PiUsageNormalizer.normalize(response.data),
        statistics != lastUsage
      else { return }
      try emit(.usageStatistics(statistics))
      lastUsage = statistics
    } catch {
      // Usage is optional telemetry; the execution stream remains authoritative.
    }
  }

  private func observeUserInput(_ event: PiJSONValue) throws {
    guard let message = event["message"], message["role"]?.stringValue == "user" else { return }
    let text =
      message["content"]?.stringValue
      ?? message["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue }.joined(
        separator: "\n")
    guard let text else { return }
    if !initialInputSeen && text == request.prompt {
      initialInputSeen = true
      return
    }
    guard let expected = pendingInputs.first, expected == text else { return }
    pendingInputs.removeFirst()
    pendingInputBytes -= expected.utf8.count
    try emit(.steerDispatched(text))
  }

  private func handleUI(_ value: PiJSONValue) async throws {
    if let approval = try PiExtensionUIBridge.approval(
      value, nonce: nonce, taskID: request.taskID, binding: binding)
    {
      if phase == .stopping {
        try await client.answerUI(id: approval.wireID, fields: ["cancelled": .bool(true)])
        return
      }
      guard phase == .active, approvals.count < 32,
        !approvals.values.contains(where: { $0.wireID == approval.wireID })
      else {
        throw PiRPCError.invalidRecord
      }
      approvals[approval.request.approvalID] = approval
      try emit(.approvalRequested(approval.request))
      return
    }
    if let input = try PiExtensionUserInputBridge.request(
      value, taskID: request.taskID, binding: binding
    ) {
      guard phase == .active else {
        try await client.answerUI(id: input.wireID, fields: ["cancelled": .bool(true)])
        return
      }
      guard userInputs.count < 32,
        userInputs[input.request.inputID] == nil
      else { throw PiRPCError.invalidRecord }
      userInputs[input.request.inputID] = input
      try emit(.userInputRequested(input.request))
    }
  }

  func scheduleSettlement() {
    guard phase == .active, settledObserved, inFlightInputs == 0, settlement == nil else { return }
    settlement = Task { [weak self] in await self?.settle() }
  }

  private func settle() async {
    let generation = settlementGeneration
    defer {
      settlement = nil
      if settlementGeneration != generation { scheduleSettlement() }
    }
    do {
      let state = try await client.request("get_state")
      try await waitForEvents(state.eventSequenceBarrier)
      guard phase == .active, inFlightInputs == 0, settledObserved,
        generation == settlementGeneration
      else { return }
      if let usageRefresh { await usageRefresh.value } else { await refreshUsage() }
      guard phase == .active else { return }
      guard state.data?["isStreaming"]?.boolValue == false,
        state.data?["isCompacting"]?.boolValue == false,
        state.data?["pendingMessageCount"]?.integerValue == 0
      else { return }
      guard normalizer.activeToolCount == 0, approvals.isEmpty, userInputs.isEmpty,
        pendingInputs.isEmpty
      else {
        throw PiRPCError.invalidArgument("pi_unsettled_resources")
      }
      guard normalizer.stopReason == "stop", normalizer.failure == nil,
        !normalizer.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw PiRPCError.invalidArgument("pi_incomplete_response")
      }
      await finish(.completed(summary: normalizer.summary, stopReason: "agent_settled"))
    } catch { await fail(error) }
  }

  func waitForEvents(_ barrier: Int64) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while consumedSequence < barrier {
      guard phase == .active || phase == .stopping, ContinuousClock.now < deadline else {
        throw PiRPCError.closed
      }
      try await Task.sleep(for: .milliseconds(2))
    }
  }

  func emit(_ event: AgentEvent) throws {
    guard sequence < Int64.max else { throw PiRPCError.invalidRecord }
    let value = try AgentEventEnvelope(
      taskID: request.taskID, providerID: .pi,
      providerSessionID: binding.providerSessionID, providerRunID: binding.providerRunID,
      providerSequence: sequence, event: event)
    sequence += 1
    if case .dropped = continuation.yield(value) { throw PiRPCError.oversizedFrame }
  }

  func fail(_ error: any Error) async {
    guard phase == .active || phase == .stopping else { return }
    await finish(
      .failed(code: "pi_execution_failed", summary: PiRPCProvider.failureDescription(error)))
  }

  private func streamEnded() async {
    guard phase == .active || phase == .stopping else { return }
    await fail(PiRPCError.closed)
  }

  private func checkActivity() async {
    guard phase == .active, approvals.isEmpty, userInputs.isEmpty,
      ContinuousClock.now - lastActivity > .seconds(10 * 60)
    else { return }
    await fail(PiRPCError.timedOut)
  }

  func finish(_ event: AgentEvent?) async {
    guard phase != .closed && phase != .closing else { return }
    phase = .closing
    watchdog?.cancel()
    usageRefresh?.cancel()
    usageRefresh = nil
    let inputs = Array(userInputs.values)
    userInputs.removeAll()
    for input in inputs {
      try? await client.answerUI(id: input.wireID, fields: ["cancelled": .bool(true)])
    }
    await client.shutdown()
    selectedSkillStage?.cleanup()
    reader?.cancel()
    approvals.removeAll()
    pendingInputs.removeAll()
    pendingInputBytes = 0
    if let event {
      do { try emit(event) } catch { continuation.finish(throwing: error) }
    }
    phase = .closed
    continuation.finish()
  }

  func shutdown() async { await finish(nil) }
}

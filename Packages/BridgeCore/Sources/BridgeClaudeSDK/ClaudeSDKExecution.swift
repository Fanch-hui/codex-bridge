import BridgeACP
import BridgeAgentCore
import BridgeDomain
import BridgeSecurity
import Foundation

actor ClaudeSDKExecution {
  private struct PendingUserInput {
    let wireID: ACPRequestID
    let generation: Int
    let questionText: [String: String]
    let optionLabels: [String: Set<String>]
    let multiple: Set<String>
  }

  nonisolated let events: AsyncThrowingStream<AgentEventEnvelope, any Error>
  private let eventDelivery: AgentEventStreamDelivery<AgentEventEnvelope>
  private let continuation: AsyncThrowingStream<AgentEventEnvelope, any Error>.Continuation
  private let client: ClaudeSDKClient
  private let request: AgentExecutionRequest
  private let binding: AgentBinding
  private let sessionLease: String
  private let writeAdmission: ClaudeWriteAdmission?
  private let normalizer = ClaudeEventNormalizer()
  private var collector: Task<Void, Never>?
  private var terminal = false
  private var sequence: Int64 = 0
  private var inputs: [String: String] = [:]
  private var firstInputID: String?
  private var permissions: [String: (wireID: ACPRequestID, digest: String, generation: Int)] = [:]
  private var userInputs: [String: PendingUserInput] = [:]
  private var interactionGeneration = 0
  private var cancelledInteractionGeneration = -1
  private var interruptInProgress = false

  init(
    client: ClaudeSDKClient, request: AgentExecutionRequest, binding: AgentBinding,
    sessionLease: String
  ) {
    self.client = client
    self.request = request
    self.binding = binding
    self.sessionLease = sessionLease
    writeAdmission = request.toolWriteGate.map { ClaudeWriteAdmission(gate: $0, client: client) }
    let stream = AsyncThrowingStream.makeStream(
      of: AgentEventEnvelope.self, throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(128))
    events = stream.stream
    continuation = stream.continuation
    eventDelivery = AgentEventStreamDelivery(stream.continuation)
  }

  func start() async throws {
    guard collector == nil else { return }
    let source = client.events
    collector = Task { [weak self] in
      do {
        for try await event in source {
          guard let self else { return }
          try await self.consume(event)
        }
        await self?.fail()
      } catch { await self?.fail() }
    }
    do {
      try await send(request.executionPrompt, initial: true)
    } catch {
      await finish()
      throw error
    }
  }

  func send(_ text: String, initial: Bool = false, interrupt: Bool = false) async throws {
    guard !terminal, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf8.count <= (initial ? 65536 : 32768), !text.contains("\0"), inputs.count < 32
    else { throw AgentRuntimeError.invalidRequest("claude.input") }
    if interrupt {
      guard !interruptInProgress else {
        throw AgentRuntimeError.invalidRequest("claude.interrupt_busy")
      }
      interruptInProgress = true
    }
    defer { if interrupt { interruptInProgress = false } }
    if interrupt { try await cancelCurrentInteractions() }
    let id = UUID().uuidString.lowercased()
    var fields: [String: ClaudeJSONValue] = ["id": .string(id), "text": .string(text)]
    if initial, !request.attachments.isEmpty {
      fields["images"] = .array(
        try request.attachments.enumerated().map { index, attachment in
          let image: SecureProjectImageData
          if let contents = request.attachmentContents {
            image = try SecureProjectImageReader.verify(
              contents[index].data, attachment: attachment)
          } else {
            image = try SecureProjectImageReader.read(attachment, projectRoot: request.projectRoot)
          }
          return .object([
            "mimeType": .string(attachment.mimeType),
            "data": .string(image.data.base64EncodedString()),
          ])
        })
    }
    let input = ClaudeJSONValue.object(fields)
    inputs[id] = text
    if initial { firstInputID = id }
    do {
      let response = try await client.request(
        interrupt ? "claude/interrupt" : "claude/input",
        params: interrupt ? .object(["continuation": input]) : input,
        timeout: interrupt ? .seconds(150) : nil)
      guard response["accepted"]?.boolValue == true, response["inputID"]?.stringValue == id else {
        throw ACPError.invalidMessage
      }
    } catch {
      inputs.removeValue(forKey: id)
      throw error
    }
  }

  func interrupt() async throws {
    guard !terminal else { throw AgentRuntimeError.processUnavailable }
    guard !interruptInProgress else {
      throw AgentRuntimeError.invalidRequest("claude.interrupt_busy")
    }
    interruptInProgress = true
    defer { interruptInProgress = false }
    try await cancelCurrentInteractions()
    _ = try await client.request("claude/interrupt", timeout: .seconds(150))
  }

  func resolveUserInput(_ inputID: String, response: AgentUserInputResponse) async throws {
    guard !terminal, let pending = userInputs[inputID] else {
      throw AgentRuntimeError.approvalUnavailable(inputID)
    }
    let result: ClaudeJSONValue
    switch response {
    case .cancelled:
      result = .object(["cancelled": .bool(true)])
    case .answers(let answers):
      guard Set(answers.keys) == Set(pending.questionText.keys) else {
        throw AgentRuntimeError.invalidRequest("claude.user_input_answers")
      }
      var selected: [String: ClaudeJSONValue] = [:]
      for (id, values) in answers {
        guard let options = pending.optionLabels[id],
          !values.isEmpty, values.count <= options.count + 1,
          pending.multiple.contains(id) || values.count == 1,
          Set(values).count == values.count,
          values.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              && $0.utf8.count <= 4096 && !$0.contains("\0")
          })
        else { throw AgentRuntimeError.invalidRequest("claude.user_input_answers") }
        selected[id] = .array(values.map(ClaudeJSONValue.string))
      }
      result = .object(["answers": .object(selected)])
    }
    userInputs.removeValue(forKey: inputID)
    try await client.resolveUserInput(pending.wireID, result: result)
  }

  func resolveApproval(_ id: String, option: String) async throws {
    guard let pending = permissions[id],
      ["allow_once", "allow_for_session", "deny"].contains(option), !terminal
    else { throw AgentRuntimeError.approvalUnavailable(id) }
    permissions.removeValue(forKey: id)
    try await client.resolve(
      pending.wireID,
      result: .object([
        "option": .string(option), "digest": .string(pending.digest),
      ]))
  }

  func consume(_ event: ClaudeHostEvent) async throws {
    guard !terminal else { return }
    switch event {
    case .permission(let id, let value):
      try validateIdentity(value)
      guard try acceptsInteraction(value) else { return }
      try await permission(id, value: value)
    case .userInput(let id, let value):
      try validateIdentity(value)
      guard try acceptsInteraction(value) else { return }
      try await userInput(id, value: value)
    case .workspaceWrite(let id, let value):
      try validateIdentity(value)
      guard let writeAdmission else { throw ACPError.invalidMessage }
      try await writeAdmission.handle(id, value)
    case .update(let value):
      try validateIdentity(value)
      if value["kind"]?.stringValue == "interactions_cancelled" {
        guard let generation = value["interactionGeneration"]?.intValue,
          generation >= 0, generation <= interactionGeneration
        else { throw ACPError.invalidMessage }
        try await cancelInteractions(through: generation)
        if generation == interactionGeneration {
          guard interactionGeneration < Int.max else { throw ACPError.invalidMessage }
          interactionGeneration += 1
        }
        return
      }
      if value["kind"]?.stringValue == "inputs_cancelled" {
        guard let ids = value["inputIDs"]?.arrayValue, ids.count <= 32 else {
          throw ACPError.invalidMessage
        }
        for item in ids {
          guard let id = item.stringValue, inputs.removeValue(forKey: id) != nil else {
            throw ACPError.invalidMessage
          }
        }
        return
      }
      if value["kind"]?.stringValue == "input_dispatched" {
        guard let id = value["inputID"]?.stringValue, let text = inputs.removeValue(forKey: id),
          value["text"]?.stringValue == text
        else { throw ACPError.invalidMessage }
        if id != firstInputID { try await emit(.steerDispatched(text)) }
        return
      }
      if let normalized = try normalizer.normalize(value) {
        switch normalized {
        case .completed, .failed, .interrupted:
          await finish(with: normalized)
        default: try await emit(normalized)
        }
      }
    }
  }

  private func acceptsInteraction(_ value: ClaudeJSONValue) throws -> Bool {
    guard let generation = value["interactionGeneration"]?.intValue,
      generation >= 0, generation <= interactionGeneration
    else { throw ACPError.invalidMessage }
    return generation > cancelledInteractionGeneration
  }

  private func cancelCurrentInteractions() async throws {
    guard interactionGeneration < Int.max else { throw ACPError.invalidMessage }
    let generation = interactionGeneration
    interactionGeneration += 1
    try await cancelInteractions(through: generation)
  }

  private func cancelInteractions(through generation: Int) async throws {
    guard generation > cancelledInteractionGeneration else { return }
    cancelledInteractionGeneration = max(cancelledInteractionGeneration, generation)
    let approvalIDs = permissions.compactMap { $0.value.generation <= generation ? $0.key : nil }
    let userInputIDs = userInputs.compactMap { $0.value.generation <= generation ? $0.key : nil }
    for id in approvalIDs { permissions.removeValue(forKey: id) }
    for id in userInputIDs { userInputs.removeValue(forKey: id) }
    await client.cancelInteractions(through: generation)
    try await emit(.interactionsCancelled(approvalIDs: approvalIDs, userInputIDs: userInputIDs))
  }

  private func validateIdentity(_ value: ClaudeJSONValue) throws {
    guard value["sessionID"]?.stringValue == binding.providerSessionID,
      value["runID"]?.stringValue == binding.providerRunID,
      value["taskID"]?.stringValue == request.taskID.rawValue
    else { throw AgentRuntimeError.sessionMismatch }
  }

  private func userInput(_ wireID: ACPRequestID, value: ClaudeJSONValue) async throws {
    guard userInputs.count < 16, let itemID = value["toolUseID"]?.stringValue,
      let generation = value["interactionGeneration"]?.intValue,
      let values = value["questions"]?.arrayValue, (1...4).contains(values.count)
    else { throw ACPError.invalidMessage }
    var questions: [AgentUserInputQuestion] = []
    var questionText: [String: String] = [:]
    var optionLabels: [String: Set<String>] = [:]
    var multiple = Set<String>()
    for (index, value) in values.enumerated() {
      guard let text = value["question"]?.stringValue, let header = value["header"]?.stringValue,
        let options = value["options"]?.arrayValue, (2...4).contains(options.count)
      else { throw ACPError.invalidMessage }
      let id = String(index)
      let parsed = try options.map { option -> AgentUserInputOption in
        guard let label = option["label"]?.stringValue else { throw ACPError.invalidMessage }
        return try AgentUserInputOption(
          label: label, description: option["description"]?.stringValue ?? "")
      }
      let allowsMultiple = value["multiSelect"]?.boolValue ?? false
      questions.append(
        try AgentUserInputQuestion(
          id: id, header: header, question: text, kind: .select,
          options: parsed, allowsMultiple: allowsMultiple, allowsCustomText: true))
      questionText[id] = text
      optionLabels[id] = Set(parsed.map(\.label))
      if allowsMultiple { multiple.insert(id) }
    }
    let inputID = "claude-input-" + UUID().uuidString.lowercased()
    let summary = questions.map(\.header).joined(separator: "、")
    let userRequest = try AgentUserInputRequest(
      inputID: inputID, taskID: request.taskID, binding: binding,
      providerItemID: itemID, title: "Claude 需要你的选择", summary: summary, questions: questions)
    userInputs[inputID] = PendingUserInput(
      wireID: wireID, generation: generation, questionText: questionText,
      optionLabels: optionLabels, multiple: multiple)
    try await emit(.userInputRequested(userRequest))
  }

  private func permission(_ wireID: ACPRequestID, value: ClaudeJSONValue) async throws {
    guard permissions.count < 32, let tool = value["tool"]?.stringValue,
      let generation = value["interactionGeneration"]?.intValue,
      let itemID = value["toolUseID"]?.stringValue, let digest = value["digest"]?.stringValue,
      digest.count == 64,
      digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      let pathValues = value["relativePaths"]?.arrayValue, pathValues.count <= 1
    else { throw ACPError.invalidMessage }
    let paths = pathValues.compactMap(\.stringValue)
    guard paths.count == pathValues.count else { throw ACPError.invalidMessage }
    let id = "claude-" + UUID().uuidString.lowercased()
    let command = value["command"]?.stringValue
    let network = value["networkTarget"]?.stringValue
    let kind: AgentApprovalKind =
      command != nil ? .command : network != nil ? .network : paths.isEmpty ? .tool : .fileChange
    let approval = try AgentApprovalRequest(
      approvalID: id, taskID: request.taskID, binding: binding,
      providerItemID: itemID, kind: kind, title: "Claude Code 请求执行 \(tool)",
      normalizedPayloadDigest: digest, relativePaths: paths, normalizedCommand: command,
      networkTarget: network,
      options: [
        AgentApprovalOption(id: "allow_once", name: "仅本次允许", kind: "allow_once"),
        AgentApprovalOption(id: "allow_for_session", name: "本次运行允许相同操作", kind: "allow_for_session"),
        AgentApprovalOption(id: "deny", name: "拒绝", kind: "reject_once"),
      ])
    permissions[id] = (wireID, digest, generation)
    try await emit(.approvalRequested(approval))
  }

  private func emit(_ event: AgentEvent) async throws {
    guard sequence < Int64.max else { throw ACPError.invalidMessage }
    let envelope = try AgentEventEnvelope(
      taskID: request.taskID, providerID: .claudeCode,
      providerSessionID: binding.providerSessionID, providerRunID: binding.providerRunID,
      providerSequence: sequence, event: event)
    sequence += 1
    guard await eventDelivery.enqueue(envelope) else { throw ACPError.transportClosed }
  }

  private func fail() async {
    await finish(
      with: .failed(code: "claude_transport_failed", summary: "Claude 执行通道关闭，任务结果未确认。"))
  }

  private func finish(with event: AgentEvent? = nil) async {
    guard !terminal else {
      await client.shutdown()
      return
    }
    terminal = true
    collector?.cancel()
    permissions.removeAll()
    userInputs.removeAll()
    inputs.removeAll()
    let stopped = await client.shutdown()
    if stopped { await ClaudeSessionLeases.shared.release(sessionLease) }
    await writeAdmission?.close(releasingHeld: stopped)
    do {
      if !stopped {
        try await emit(
          .failed(
            code: "claude_process_unknown", summary: "Claude Code 后台进程尚未确认退出，请核对后恢复。"))
      } else if let event {
        try await emit(event)
      }
      continuation.finish()
    } catch {
      continuation.finish(throwing: error)
    }
  }

  func shutdown() async {
    continuation.finish()
    await finish()
  }
}

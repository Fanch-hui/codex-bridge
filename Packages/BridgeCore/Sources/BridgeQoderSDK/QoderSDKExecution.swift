import BridgeACP
import BridgeAgentCore
import BridgeDomain
import BridgeSecurity
import Foundation

actor QoderSDKExecution {
  private struct PendingUserInput {
    let wireID: ACPRequestID
    let questionText: [String: String]
    let optionLabels: [String: Set<String>]
    let multiple: Set<String>
  }

  nonisolated let events: AsyncThrowingStream<AgentEventEnvelope, any Error>
  private let continuation: AsyncThrowingStream<AgentEventEnvelope, any Error>.Continuation
  private let client: QoderSDKClient
  private let request: AgentExecutionRequest
  private let binding: AgentBinding
  private let distribution: QoderDistribution
  private let normalizer = QoderEventNormalizer()
  private var collector: Task<Void, Never>?
  private var terminal = false
  private var sequence: Int64 = 0
  private var inputs: [String: String] = [:]
  private var firstInputID: String?
  private var permissions: [String: (wireID: ACPRequestID, digest: String)] = [:]
  private var userInputs: [String: PendingUserInput] = [:]

  init(
    client: QoderSDKClient, request: AgentExecutionRequest, binding: AgentBinding,
    distribution: QoderDistribution
  ) {
    self.client = client
    self.request = request
    self.binding = binding
    self.distribution = distribution
    let stream = AsyncThrowingStream.makeStream(
      of: AgentEventEnvelope.self, throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(128))
    events = stream.stream
    continuation = stream.continuation
  }

  func start() {
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
    Task { [weak self] in
      guard let self else { return }
      do { try await self.send(self.request.prompt, initial: true) } catch { await self.fail() }
    }
  }

  func send(_ text: String, initial: Bool = false, interrupt: Bool = false) async throws {
    guard !terminal, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf8.count <= 32768, !text.contains("\0"), inputs.count < 32
    else { throw AgentRuntimeError.invalidRequest("qoder.input") }
    let id = UUID().uuidString.lowercased()
    var fields: [String: QoderJSONValue] = ["id": .string(id), "text": .string(text)]
    if initial, !request.attachments.isEmpty {
      fields["images"] = .array(
        try request.attachments.map { attachment in
          let image = try SecureProjectImageReader.read(
            attachment,
            projectRoot: request.projectRoot
          )
          return .object([
            "mimeType": .string(attachment.mimeType),
            "data": .string(image.data.base64EncodedString()),
          ])
        })
    }
    let input = QoderJSONValue.object(fields)
    inputs[id] = text
    if initial { firstInputID = id }
    do {
      let response = try await client.request(
        interrupt ? "qoder/interrupt" : "qoder/input",
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
    for inputID in Array(userInputs.keys) {
      try? await resolveUserInput(inputID, response: .cancelled)
    }
    _ = try await client.request("qoder/interrupt", timeout: .seconds(150))
  }

  func resolveUserInput(_ inputID: String, response: AgentUserInputResponse) async throws {
    guard !terminal, let pending = userInputs[inputID] else {
      throw AgentRuntimeError.invalidRequest("qoder.user_input_unavailable")
    }
    let result: QoderJSONValue
    switch response {
    case .cancelled:
      result = .object(["cancelled": .bool(true)])
    case .answers(let answers):
      guard Set(answers.keys) == Set(pending.questionText.keys) else {
        throw AgentRuntimeError.invalidRequest("qoder.user_input_answers")
      }
      var selected: [String: QoderJSONValue] = [:]
      for (id, values) in answers {
        guard let options = pending.optionLabels[id],
          !values.isEmpty, values.count <= options.count + 1,
          pending.multiple.contains(id) || values.count == 1,
          Set(values).count == values.count,
          values.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              && $0.utf8.count <= 4096 && !$0.contains("\0")
          })
        else { throw AgentRuntimeError.invalidRequest("qoder.user_input_answers") }
        selected[id] = .array(values.map(QoderJSONValue.string))
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

  private func consume(_ event: QoderHostEvent) async throws {
    guard !terminal else { return }
    switch event {
    case .permission(let id, let value): try await permission(id, value: value)
    case .userInput(let id, let value): try userInput(id, value: value)
    case .update(let value):
      guard value["sessionID"]?.stringValue == binding.providerSessionID,
        value["distribution"]?.stringValue == distribution.rawValue
      else { throw AgentRuntimeError.sessionMismatch }
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
        if id != firstInputID { try emit(.steerDispatched(text)) }
        return
      }
      if let normalized = try normalizer.normalize(value) {
        switch normalized {
        case .completed, .failed, .interrupted:
          terminal = true
          try emit(normalized)
          continuation.finish()
        default: try emit(normalized)
        }
      }
    }
  }

  private func userInput(_ wireID: ACPRequestID, value: QoderJSONValue) throws {
    guard userInputs.count < 16, let itemID = value["toolUseID"]?.stringValue,
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
    let inputID = "qoder-input-" + UUID().uuidString.lowercased()
    let summary = questions.map(\.header).joined(separator: "、")
    let userRequest = try AgentUserInputRequest(
      inputID: inputID, taskID: request.taskID, binding: binding,
      providerItemID: itemID, title: "Qoder 需要你的选择", summary: summary, questions: questions)
    userInputs[inputID] = PendingUserInput(
      wireID: wireID, questionText: questionText,
      optionLabels: optionLabels, multiple: multiple)
    try emit(.userInputRequested(userRequest))
  }

  private func permission(_ wireID: ACPRequestID, value: QoderJSONValue) async throws {
    guard permissions.count < 32, let tool = value["tool"]?.stringValue,
      let itemID = value["toolUseID"]?.stringValue, let digest = value["digest"]?.stringValue,
      digest.count == 64,
      digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      let pathValues = value["relativePaths"]?.arrayValue, pathValues.count <= 1
    else { throw ACPError.invalidMessage }
    let paths = pathValues.compactMap(\.stringValue)
    guard paths.count == pathValues.count else { throw ACPError.invalidMessage }
    let id = "qoder-" + UUID().uuidString.lowercased()
    let command = value["command"]?.stringValue
    let network = value["networkTarget"]?.stringValue
    let kind: AgentApprovalKind =
      command != nil ? .command : network != nil ? .network : paths.isEmpty ? .tool : .fileChange
    let approval = try AgentApprovalRequest(
      approvalID: id, taskID: request.taskID, binding: binding,
      providerItemID: itemID, kind: kind, title: "\(distribution.displayName) 请求执行 \(tool)",
      normalizedPayloadDigest: digest, relativePaths: paths, normalizedCommand: command,
      networkTarget: network,
      options: [
        AgentApprovalOption(id: "allow_once", name: "仅本次允许", kind: "allow_once"),
        AgentApprovalOption(id: "allow_for_session", name: "本次运行允许相同操作", kind: "allow_for_session"),
        AgentApprovalOption(id: "deny", name: "拒绝", kind: "reject_once"),
      ])
    permissions[id] = (wireID, digest)
    try emit(.approvalRequested(approval))
  }

  private func emit(_ event: AgentEvent) throws {
    guard sequence < Int64.max else { throw ACPError.invalidMessage }
    let envelope = try AgentEventEnvelope(
      taskID: request.taskID, providerID: .qoder,
      providerSessionID: binding.providerSessionID, providerRunID: binding.providerRunID,
      providerSequence: sequence, event: event)
    sequence += 1
    if case .dropped = continuation.yield(envelope) { throw ACPError.oversizedFrame }
  }

  private func fail() async {
    guard !terminal else { return }
    terminal = true
    await client.shutdown()
    try? emit(.failed(code: "qoder_transport_failed", summary: "Qoder 执行通道关闭，任务结果未确认。"))
    continuation.finish()
  }

  func shutdown() async {
    terminal = true
    await client.shutdown()
    collector?.cancel()
    permissions.removeAll()
    userInputs.removeAll()
    inputs.removeAll()
    continuation.finish()
  }
}

import BridgeAgentCore
import BridgeDomain
import Foundation

struct PiExtensionUserInput: Sendable {
  enum Kind: Sendable {
    case select(Set<String>)
    case confirm
    case text
    case questionnaire([AgentUserInputQuestion])
  }

  let request: AgentUserInputRequest
  let wireID: String
  let kind: Kind

  func responseFields(for response: AgentUserInputResponse) throws -> [String: PiJSONValue] {
    guard case .answers(let answers) = response else { return ["cancelled": .bool(true)] }
    if case .questionnaire(let questions) = kind {
      return try PiExtensionUserInputBridge.questionnaireResponseFields(
        answers, questions: questions)
    }
    guard Set(answers.keys) == ["answer"], let values = answers["answer"], values.count == 1,
      let value = values.first, !value.contains("\0"), value.utf8.count <= 4 * 1_024
    else { throw AgentRuntimeError.invalidRequest("pi.user_input_answer") }
    switch kind {
    case .select(let options):
      guard options.contains(value) else {
        throw AgentRuntimeError.invalidRequest("pi.user_input_answer")
      }
      return ["value": .string(value)]
    case .confirm:
      guard value == "是" || value == "否" else {
        throw AgentRuntimeError.invalidRequest("pi.user_input_answer")
      }
      return ["confirmed": .bool(value == "是")]
    case .text:
      guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AgentRuntimeError.invalidRequest("pi.user_input_answer")
      }
      return ["value": .string(value)]
    case .questionnaire:
      throw AgentRuntimeError.invalidRequest("pi.user_input_answer")
    }
  }
}

enum PiExtensionUserInputBridge {
  private static let questionnairePrefix = "codex-bridge.pi.questionnaire.v1:"

  static func request(
    _ value: PiJSONValue,
    taskID: TaskID,
    binding: AgentBinding
  ) throws -> PiExtensionUserInput? {
    guard let method = value["method"]?.stringValue,
      ["select", "confirm", "input", "editor"].contains(method)
    else { return nil }
    guard let wireID = value["id"]?.stringValue, !wireID.isEmpty,
      wireID == wireID.trimmingCharacters(in: .whitespacesAndNewlines),
      wireID.utf8.count <= 128, wireID.rangeOfCharacter(from: .controlCharacters) == nil,
      let title = value["title"]?.stringValue
    else { throw PiRPCError.invalidRecord }
    if title.hasPrefix(questionnairePrefix) {
      return try questionnaireRequest(
        title: title, wireID: wireID, taskID: taskID, binding: binding)
    }
    guard title.utf8.count <= 1_024,
      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let payload = try? question(method: method, title: title, value: value)
    else { throw PiRPCError.invalidRecord }
    let timeoutSeconds = try parseTimeoutSeconds(value["timeout"])
    let question = try AgentUserInputQuestion(
      id: "answer", header: payload.header, question: payload.prompt,
      kind: payload.kind, options: payload.options,
      allowsCustomText: payload.kind == .input || payload.kind == .editor)
    let request = try AgentUserInputRequest(
      inputID: wireID, taskID: taskID, binding: binding, providerItemID: wireID,
      title: "Pi 需要输入", summary: payload.summary, questions: [question],
      timeoutSeconds: timeoutSeconds)
    return PiExtensionUserInput(request: request, wireID: wireID, kind: payload.responseKind)
  }

  private static func questionnaireRequest(
    title: String, wireID: String, taskID: TaskID, binding: AgentBinding
  ) throws -> PiExtensionUserInput {
    guard title.utf8.count <= 24 * 1_024,
      let data = String(title.dropFirst(questionnairePrefix.count)).data(using: .utf8),
      let payload = try? JSONDecoder().decode(PiJSONValue.self, from: data),
      payload["revision"]?.integerValue == 1,
      let displayTitle = payload["title"]?.stringValue,
      let summary = payload["summary"]?.stringValue,
      let rawQuestions = payload["questions"]?.arrayValue,
      rawQuestions.count > 0 && rawQuestions.count <= 16
    else { throw PiRPCError.invalidRecord }
    let questions = try rawQuestions.map(questionnaireQuestion)
    let timeoutSeconds = payload["timeoutSeconds"]?.integerValue
    guard timeoutSeconds.map({ (1...3_600).contains($0) }) ?? false else {
      throw PiRPCError.invalidRecord
    }
    let request = try AgentUserInputRequest(
      inputID: wireID, taskID: taskID, binding: binding, providerItemID: wireID,
      title: displayTitle, summary: summary, questions: questions,
      timeoutSeconds: timeoutSeconds)
    return PiExtensionUserInput(request: request, wireID: wireID, kind: .questionnaire(questions))
  }

  fileprivate static func questionnaireResponseFields(
    _ answers: [String: [String]], questions: [AgentUserInputQuestion]
  ) throws -> [String: PiJSONValue] {
    let byID = Dictionary(uniqueKeysWithValues: questions.map { ($0.id, $0) })
    guard answers.keys.allSatisfy({ byID[$0] != nil }) else {
      throw AgentRuntimeError.invalidRequest("pi.user_input_answer")
    }
    for question in questions {
      guard let values = answers[question.id] else {
        if question.isRequired { throw AgentRuntimeError.invalidRequest("pi.user_input_answer") }
        continue
      }
      guard !values.isEmpty, values.count <= 32,
        question.allowsMultiple || values.count == 1,
        values.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 4 * 1_024 }),
        question.allowsCustomText
          || values.allSatisfy({ value in question.options.contains(where: { $0.label == value }) })
      else { throw AgentRuntimeError.invalidRequest("pi.user_input_answer") }
    }
    let data = try JSONEncoder().encode(["answers": answers])
    guard data.count <= 32 * 1_024, let encoded = String(data: data, encoding: .utf8) else {
      throw AgentRuntimeError.invalidRequest("pi.user_input_answer")
    }
    return ["value": .string(encoded)]
  }

  private static func questionnaireQuestion(_ value: PiJSONValue) throws -> AgentUserInputQuestion {
    guard let id = value["id"]?.stringValue,
      let header = value["header"]?.stringValue,
      let prompt = value["question"]?.stringValue,
      let rawKind = value["kind"]?.stringValue,
      let kind = AgentUserInputKind(rawValue: rawKind)
    else { throw PiRPCError.invalidRecord }
    let rawOptions = value["options"]?.arrayValue ?? []
    guard rawOptions.count <= 32 else { throw PiRPCError.invalidRecord }
    let options = try rawOptions.map { item -> AgentUserInputOption in
      guard let label = item["label"]?.stringValue,
        let description = item["description"]?.stringValue
      else { throw PiRPCError.invalidRecord }
      return try AgentUserInputOption(label: label, description: description)
    }
    return try AgentUserInputQuestion(
      id: id, header: header, question: prompt, kind: kind, options: options,
      allowsMultiple: value["allowsMultiple"]?.boolValue == true,
      allowsCustomText: value["allowsCustomText"]?.boolValue == true,
      isSecret: value["isSecret"]?.boolValue == true,
      isRequired: value["isRequired"]?.boolValue != false)
  }

  private static func question(
    method: String,
    title: String,
    value: PiJSONValue
  ) throws -> QuestionPayload {
    switch method {
    case "select":
      guard let rawOptions = value["options"]?.arrayValue, !rawOptions.isEmpty,
        rawOptions.count <= 32
      else { throw PiRPCError.invalidRecord }
      let labels = rawOptions.compactMap(\.stringValue)
      guard labels.count == rawOptions.count else { throw PiRPCError.invalidRecord }
      return QuestionPayload(
        header: title, prompt: title, summary: title, kind: .select,
        options: try labels.map { try AgentUserInputOption(label: $0) },
        responseKind: .select(Set(labels)))
    case "confirm":
      let message = value["message"]?.stringValue
      let prompt = message.flatMap(nonEmpty) ?? title
      return QuestionPayload(
        header: title, prompt: prompt, summary: prompt, kind: .confirm,
        options: [try AgentUserInputOption(label: "是"), try AgentUserInputOption(label: "否")],
        responseKind: .confirm)
    case "input":
      let placeholder = value["placeholder"]?.stringValue.flatMap(nonEmpty) ?? "请输入回答。"
      return QuestionPayload(
        header: title, prompt: placeholder, summary: title, kind: .input,
        options: [], responseKind: .text)
    case "editor":
      let prefill = value["prefill"]?.stringValue ?? ""
      let prefix = "请编辑以下文本后提交：\n\n"
      guard prefix.utf8.count + prefill.utf8.count <= 4 * 1_024 else {
        throw PiRPCError.invalidRecord
      }
      let prompt = prefill.isEmpty ? "请输入文本内容。" : prefix + prefill
      return QuestionPayload(
        header: title, prompt: prompt, summary: title, kind: .editor,
        options: [], responseKind: .text)
    default:
      throw PiRPCError.invalidRecord
    }
  }

  private static func parseTimeoutSeconds(_ value: PiJSONValue?) throws -> Int? {
    guard let value, value != .null else { return nil }
    guard let milliseconds = value.doubleValue, milliseconds.isFinite,
      milliseconds >= 1, milliseconds <= 3_600_000
    else { throw PiRPCError.invalidRecord }
    return Int((milliseconds / 1_000).rounded(.up))
  }

  private static func nonEmpty(_ value: String) -> String? {
    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
  }

  private struct QuestionPayload {
    let header: String
    let prompt: String
    let summary: String
    let kind: AgentUserInputKind
    let options: [AgentUserInputOption]
    let responseKind: PiExtensionUserInput.Kind
  }
}

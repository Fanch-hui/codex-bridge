import BridgeDomain
import Foundation

public enum AgentUserInputKind: String, Codable, Sendable {
  case select
  case confirm
  case input
  case editor
}

public struct AgentUserInputOption: Codable, Equatable, Sendable {
  public let label: String
  public let description: String

  public init(label: String, description: String = "") throws {
    try AgentValidation.text(label, field: "userInputOption.label", maximumBytes: 512)
    try AgentValidation.streamText(
      description, field: "userInputOption.description", maximumBytes: 1_024)
    self.label = label
    self.description = description
  }
}

public struct AgentUserInputQuestion: Codable, Equatable, Sendable {
  public let id: String
  public let header: String
  public let question: String
  public let kind: AgentUserInputKind
  public let options: [AgentUserInputOption]
  public let allowsMultiple: Bool
  public let allowsCustomText: Bool
  public let isSecret: Bool
  public let isRequired: Bool

  public init(
    id: String,
    header: String,
    question: String,
    kind: AgentUserInputKind,
    options: [AgentUserInputOption] = [],
    allowsMultiple: Bool = false,
    allowsCustomText: Bool = false,
    isSecret: Bool = false,
    isRequired: Bool = true
  ) throws {
    try AgentValidation.identifier(id, field: "userInputQuestion.id", maximumBytes: 256)
    try AgentValidation.text(header, field: "userInputQuestion.header", maximumBytes: 512)
    try AgentValidation.text(question, field: "userInputQuestion.question", maximumBytes: 4_096)
    guard options.count <= 32,
      Set(options.map(\.label)).count == options.count,
      (kind == .select || kind == .confirm) == !options.isEmpty,
      !allowsMultiple || kind == .select
    else {
      throw AgentRuntimeError.invalidRequest("userInputQuestion.options")
    }
    self.id = id
    self.header = header
    self.question = question
    self.kind = kind
    self.options = options
    self.allowsMultiple = allowsMultiple
    self.allowsCustomText = allowsCustomText
    self.isSecret = isSecret
    self.isRequired = isRequired
  }
}

public struct AgentUserInputRequest: Codable, Equatable, Sendable {
  public let inputID: String
  public let taskID: TaskID
  public let binding: AgentBinding
  public let providerItemID: String
  public let title: String
  public let summary: String
  public let questions: [AgentUserInputQuestion]
  public let timeoutSeconds: Int?

  public init(
    inputID: String,
    taskID: TaskID,
    binding: AgentBinding,
    providerItemID: String,
    title: String,
    summary: String,
    questions: [AgentUserInputQuestion],
    timeoutSeconds: Int? = nil
  ) throws {
    try AgentValidation.identifier(inputID, field: "userInput.inputID", maximumBytes: 128)
    try AgentValidation.identifier(taskID.rawValue, field: "userInput.taskID", maximumBytes: 128)
    try AgentValidation.identifier(
      providerItemID, field: "userInput.providerItemID", maximumBytes: 256)
    try AgentValidation.text(title, field: "userInput.title", maximumBytes: 1_024)
    try AgentValidation.text(summary, field: "userInput.summary", maximumBytes: 4 * 1_024)
    guard !questions.isEmpty, questions.count <= 16,
      Set(questions.map(\.id)).count == questions.count,
      timeoutSeconds.map({ (1...3_600).contains($0) }) ?? true
    else {
      throw AgentRuntimeError.invalidRequest("userInput.questions")
    }
    let totalBytes = questions.reduce(title.utf8.count + summary.utf8.count) {
      $0 + $1.header.utf8.count + $1.question.utf8.count
        + $1.options.reduce(0) { $0 + $1.label.utf8.count + $1.description.utf8.count }
    }
    guard totalBytes <= 32 * 1_024 else {
      throw AgentRuntimeError.invalidRequest("userInput.size")
    }
    self.inputID = inputID
    self.taskID = taskID
    self.binding = binding
    self.providerItemID = providerItemID
    self.title = title
    self.summary = summary
    self.questions = questions
    self.timeoutSeconds = timeoutSeconds
  }
}

public enum AgentUserInputResponse: Equatable, Sendable {
  case answers([String: [String]])
  case cancelled
}

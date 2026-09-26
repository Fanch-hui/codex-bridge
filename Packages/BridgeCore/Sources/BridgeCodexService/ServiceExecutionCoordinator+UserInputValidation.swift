import BridgeAgentCore
import Foundation

extension ServiceExecutionCoordinator {
  static func validate(
    _ answers: [String: [String]],
    for questions: [AgentUserInputQuestion]
  ) throws {
    let questionIDs = Set(questions.map(\.id))
    guard Set(answers.keys).isSubset(of: questionIDs) else {
      throw ExecutionServiceError.invalidRequest("userInput.answers")
    }
    var totalBytes = 0
    for question in questions {
      guard let values = answers[question.id] else {
        guard !question.isRequired else {
          throw ExecutionServiceError.invalidRequest("userInput.answers")
        }
        continue
      }
      guard !values.isEmpty, values.count <= 32,
        Set(values).count == values.count,
        question.allowsMultiple || values.count == 1
      else {
        throw ExecutionServiceError.invalidRequest("userInput.answers")
      }
      let options = Set(question.options.map(\.label))
      for value in values {
        try validateUserInputValue(value, totalBytes: &totalBytes)
        guard
          question.kind == .input || question.kind == .editor
            || question.allowsCustomText || options.contains(value)
        else {
          throw ExecutionServiceError.invalidRequest("userInput.answers")
        }
      }
    }
    try validateUserInputTotalBytes(totalBytes)
  }

  static func validate(
    _ answers: [String: [String]],
    for questions: [ExecutionUserInputQuestion]
  ) throws {
    let questionIDs = Set(questions.map(\.id))
    guard Set(answers.keys).isSubset(of: questionIDs) else {
      throw ExecutionServiceError.invalidRequest("userInput.answers")
    }
    var totalBytes = 0
    for question in questions {
      guard let values = answers[question.id] else {
        guard question.isRequired != true else {
          throw ExecutionServiceError.invalidRequest("userInput.answers")
        }
        continue
      }
      guard !values.isEmpty, values.count <= 32,
        Set(values).count == values.count,
        question.allowsMultiple == true || values.count == 1
      else {
        throw ExecutionServiceError.invalidRequest("userInput.answers")
      }
      let options = Set(question.options.map(\.label))
      let permitsText =
        question.isOther
        || question.inputType == "input"
        || question.inputType == "editor"
        || options.isEmpty
      for value in values {
        try validateUserInputValue(value, totalBytes: &totalBytes)
        guard permitsText || options.contains(value) else {
          throw ExecutionServiceError.invalidRequest("userInput.answers")
        }
      }
    }
    try validateUserInputTotalBytes(totalBytes)
  }

  private static func validateUserInputValue(_ value: String, totalBytes: inout Int) throws {
    try ExecutionValidation.text(
      value,
      field: "userInput.answer",
      maximumBytes: 4 * 1_024
    )
    totalBytes += value.utf8.count
  }

  private static func validateUserInputTotalBytes(_ totalBytes: Int) throws {
    guard totalBytes <= 32 * 1_024 else {
      throw ExecutionServiceError.invalidRequest("userInput.answers")
    }
  }
}

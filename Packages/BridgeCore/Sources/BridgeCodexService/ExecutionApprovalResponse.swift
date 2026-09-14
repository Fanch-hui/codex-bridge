import BridgeCodexRPC
import BridgeServiceCore

package enum ExecutionApprovalResponse: Sendable {
  case command(execPolicyAmendment: [String]?)
  case fileChange
  case permissions(JSONValue)
  case userInput(questionIDs: Set<String>)

  var availableDecisions: [LocalApprovalDecision] {
    switch self {
    case .command(let amendment):
      var decisions: [LocalApprovalDecision] = [.allow, .allowForSession]
      if amendment?.isEmpty == false { decisions.append(.allowSimilarCommands) }
      decisions.append(.deny)
      return decisions
    case .fileChange, .permissions:
      return [.allow, .allowForSession, .deny]
    case .userInput:
      return [.allow, .deny]
    }
  }

  func value(
    for decision: LocalApprovalDecision,
    answers: [String: [String]]? = nil
  ) throws -> JSONValue {
    if answers != nil {
      guard case .userInput = self else {
        throw ExecutionServiceError.invalidRequest("approval.answers")
      }
    }
    guard availableDecisions.contains(decision) else {
      throw ExecutionServiceError.invalidRequest("approval.decision")
    }
    switch (self, decision) {
    case (_, .deny):
      if case .permissions = self {
        return .object([
          "permissions": .object([:]),
          "scope": .string("turn"),
          "strictAutoReview": .bool(false),
        ])
      }
      if case .userInput = self {
        return .object(["answers": .object([:])])
      }
      return .object(["decision": .string("decline")])
    case (.command, .allow):
      return .object(["decision": .string("accept")])
    case (.command, .allowForSession), (.fileChange, .allowForSession):
      return .object(["decision": .string("acceptForSession")])
    case (.command(let amendment), .allowSimilarCommands):
      guard let amendment, !amendment.isEmpty else {
        throw ExecutionServiceError.invalidRequest("approval.decision")
      }
      return .object([
        "decision": .object([
          "acceptWithExecpolicyAmendment": .object([
            "execpolicy_amendment": .array(amendment.map(JSONValue.string))
          ])
        ])
      ])
    case (.fileChange, .allow):
      return .object(["decision": .string("accept")])
    case (.permissions(let permissions), .allow),
      (.permissions(let permissions), .allowForSession):
      return .object([
        "permissions": permissions,
        "scope": .string(decision == .allow ? "turn" : "session"),
        "strictAutoReview": .bool(false),
      ])
    case (.userInput(let questionIDs), .allow):
      guard let answers else {
        throw ExecutionServiceError.invalidRequest("approval.answers")
      }
      return .object(["answers": .object(try answerValues(answers, questionIDs: questionIDs))])
    case (.userInput, .allowForSession),
      (.userInput, .allowSimilarCommands),
      (.fileChange, .allowSimilarCommands),
      (.permissions, .allowSimilarCommands):
      throw ExecutionServiceError.invalidRequest("approval.decision")
    }
  }

  private func answerValues(
    _ answers: [String: [String]],
    questionIDs: Set<String>
  ) throws -> [String: JSONValue] {
    guard Set(answers.keys) == questionIDs, answers.count <= CodexApprovalWireLimits.arrayCount
    else {
      throw ExecutionServiceError.invalidRequest("approval.answers")
    }
    var values: [String: JSONValue] = [:]
    for (questionID, answerList) in answers {
      guard questionIDs.contains(questionID) else {
        throw ExecutionServiceError.invalidRequest("approval.answers")
      }
      try ExecutionValidation.identifier(
        questionID,
        field: "approval.answers.id",
        maximumBytes: CodexApprovalWireLimits.identifierBytes
      )
      guard !answerList.isEmpty, answerList.count <= CodexApprovalWireLimits.arrayCount else {
        throw ExecutionServiceError.invalidRequest("approval.answers")
      }
      for answer in answerList {
        try ExecutionValidation.text(
          answer,
          field: "approval.answers.value",
          maximumBytes: CodexApprovalWireLimits.stringBytes
        )
      }
      values[questionID] = .object(["answers": .array(answerList.map(JSONValue.string))])
    }
    return values
  }
}

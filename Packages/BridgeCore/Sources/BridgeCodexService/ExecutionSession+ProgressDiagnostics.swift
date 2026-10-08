import BridgeCodexRPC

extension ExecutionSession {
  static func semanticFailureSummary(method: String, error: Error) -> String {
    let methodName: String
    switch method {
    case "item/completed", "turn/plan/updated": methodName = method
    default: methodName = "unknown"
    }
    return "Codex emitted invalid task progress. method=\(methodName); "
      + semanticFailureReason(error) + "."
  }

  private static func semanticFailureReason(_ error: Error) -> String {
    if let error = error as? CodexApprovalWireError {
      switch error {
      case .unsupportedRequestMethod:
        return "unsupportedRequestMethod"
      case .unsupportedItemType:
        return "unsupportedItemType"
      case .missingField(let field):
        return "missingField(field=\(diagnosticLabel(field)))"
      case .invalidField(let field):
        return "invalidField(field=\(diagnosticLabel(field)))"
      case .unknownField(let context, _):
        return "unknownField(context=\(diagnosticLabel(context)))"
      case .unknownDiscriminator(let field, _):
        return "unknownDiscriminator(field=\(diagnosticLabel(field)))"
      case .stringTooLarge(let field, let maximumBytes):
        return "stringTooLarge(field=\(diagnosticLabel(field)), maximumBytes=\(maximumBytes))"
      case .arrayTooLarge(let field, let maximumCount):
        return "arrayTooLarge(field=\(diagnosticLabel(field)), maximumCount=\(maximumCount))"
      case .evidenceTooLarge(let maximumBytes):
        return "evidenceTooLarge(maximumBytes=\(maximumBytes))"
      }
    }
    if let error = error as? ExecutionServiceError {
      switch error {
      case .bindingMismatch:
        return "bindingMismatch"
      case .protocolViolation(let reason):
        return "protocolViolation(reason=\(diagnosticLabel(reason)))"
      case .invalidRequest(let field):
        return "invalidRequest(field=\(diagnosticLabel(field)))"
      default:
        return "executionValidationFailed"
      }
    }
    return "unrecognizedError"
  }

  private static func diagnosticLabel(_ value: String) -> String {
    ExecutionValidation.redacted(value, maximumBytes: 256) ?? "unknown"
  }
}

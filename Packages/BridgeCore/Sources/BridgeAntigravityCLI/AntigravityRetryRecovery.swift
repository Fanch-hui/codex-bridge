/// Tracks per-turn evidence that Antigravity recovered from a failed model request.
///
/// When a model request fails, `agy` records an `error_message` step such as
/// `API error (attempt 1): …` and retries. A later successful attempt produces a new
/// `agent_response` step, yet the terminal result can still report `ERROR` with the
/// earlier attempt's message. A turn counts as recovered only when an answer step
/// follows the last error step, so a failure after the final attempt stays a failure.
struct AntigravityRetryRecovery: Sendable {
  private var lastErrorStepIndex: Int?
  private var lastResponseStepIndex: Int?

  mutating func observe(_ update: AntigravityStepUpdate) {
    switch update.stepType {
    case "error_message":
      lastErrorStepIndex = max(lastErrorStepIndex ?? update.stepIndex, update.stepIndex)
    case "agent_response":
      guard update.state == "DONE" || !(update.textDelta ?? "").isEmpty else { return }
      lastResponseStepIndex = max(lastResponseStepIndex ?? update.stepIndex, update.stepIndex)
    default:
      return
    }
  }

  /// Whether a non-success result only repeats an error that a later attempt overcame.
  func recovered(status: String, response: String) -> Bool {
    guard status == "ERROR",
      !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let errorIndex = lastErrorStepIndex,
      let responseIndex = lastResponseStepIndex
    else { return false }
    return responseIndex > errorIndex
  }

  mutating func reset() {
    lastErrorStepIndex = nil
    lastResponseStepIndex = nil
  }
}

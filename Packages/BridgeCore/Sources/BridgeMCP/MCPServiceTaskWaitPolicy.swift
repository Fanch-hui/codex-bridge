import Foundation

public struct MCPServiceTaskWaitPolicy: Codable, Equatable, Sendable {
  public let waitProfile: String?
  public let recommendedPollAfterSeconds: Int
  public let diagnosticAfterQuietSeconds: Int
  public let terminal: Bool
  public let nextAction: String
  public let doNotInferFailure: Bool

  public init(
    waitProfile: String?,
    recommendedPollAfterSeconds: Int,
    diagnosticAfterQuietSeconds: Int,
    terminal: Bool,
    nextAction: String,
    doNotInferFailure: Bool
  ) {
    self.waitProfile = waitProfile
    self.recommendedPollAfterSeconds = recommendedPollAfterSeconds
    self.diagnosticAfterQuietSeconds = diagnosticAfterQuietSeconds
    self.terminal = terminal
    self.nextAction = nextAction
    self.doNotInferFailure = doNotInferFailure
  }

  public static func forTask(
    status: String,
    recentActivityAvailable: Bool,
    recentActivityCount: Int
  ) -> Self {
    switch status {
    case "awaiting_local_approval", "waiting_for_codex_approval":
      return Self(
        waitProfile: "fast",
        recommendedPollAfterSeconds: 0,
        diagnosticAfterQuietSeconds: 1_800,
        terminal: false,
        nextAction: "await_local_approval",
        doNotInferFailure: true
      )
    case "queued":
      return Self(
        waitProfile: "standard",
        recommendedPollAfterSeconds: 0,
        diagnosticAfterQuietSeconds: 1_800,
        terminal: false,
        nextAction: "poll_get_task",
        doNotInferFailure: true
      )
    case "starting":
      return Self(
        waitProfile: "standard",
        recommendedPollAfterSeconds: 0,
        diagnosticAfterQuietSeconds: 1_800,
        terminal: false,
        nextAction: "poll_get_task",
        doNotInferFailure: true
      )
    case "running":
      return Self(
        waitProfile: recentActivityAvailable && recentActivityCount > 0 ? "standard" : "deep",
        recommendedPollAfterSeconds: 0,
        diagnosticAfterQuietSeconds: recentActivityAvailable && recentActivityCount > 0
          ? 1_800 : 3_600,
        terminal: false,
        nextAction: "poll_get_task",
        doNotInferFailure: true
      )
    case "completed":
      return Self(
        waitProfile: nil,
        recommendedPollAfterSeconds: 0,
        diagnosticAfterQuietSeconds: 0,
        terminal: true,
        nextAction: "read_final_report",
        doNotInferFailure: false
      )
    case "failed", "interrupted":
      return Self(
        waitProfile: nil,
        recommendedPollAfterSeconds: 0,
        diagnosticAfterQuietSeconds: 0,
        terminal: true,
        nextAction: "inspect_terminal_state",
        doNotInferFailure: false
      )
    default:
      return Self(
        waitProfile: "deep",
        recommendedPollAfterSeconds: 0,
        diagnosticAfterQuietSeconds: 3_600,
        terminal: false,
        nextAction: "inspect_task",
        doNotInferFailure: true
      )
    }
  }

  public static func forUserInput() -> Self {
    Self(
      waitProfile: "fast",
      recommendedPollAfterSeconds: 0,
      diagnosticAfterQuietSeconds: 0,
      terminal: false,
      nextAction: "answer_user_input",
      doNotInferFailure: true
    )
  }

  private enum CodingKeys: String, CodingKey {
    case waitProfile = "wait_profile"
    case recommendedPollAfterSeconds = "recommended_poll_after_seconds"
    case diagnosticAfterQuietSeconds = "diagnostic_after_quiet_seconds"
    case terminal
    case nextAction = "next_action"
    case doNotInferFailure = "do_not_infer_failure"
  }
}

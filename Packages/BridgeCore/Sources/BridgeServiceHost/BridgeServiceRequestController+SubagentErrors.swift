import BridgeIPC
import BridgeServiceCore
import Foundation

extension BridgeServiceRequestController {
  /// Errors of the subagent round operations. Their messages are read by the controlling model,
  /// so they pass through word for word; only a missing snapshot is worth retrying.
  static func mapSubagentRoundError(_ error: any Error) -> BridgeServiceIPCError? {
    if let error = error as? SubagentRoundRejection {
      if case .snapshotUnavailable = error {
        return .init(
          code: "subagent_snapshot_unavailable", message: error.message, retryable: true)
      }
      return .init(code: "subagent_rejected", message: error.message)
    }
    guard let error = error as? SubagentSchedulerError else { return nil }
    switch error {
    case .legacyChildRequiresMigration:
      return .init(code: "subagent_migration_required", message: error.message)
    case .unknownRound:
      return .init(code: "subagent_request_not_found", message: error.message)
    case .taskMismatch, .notFinished:
      return .init(code: "subagent_rejected", message: error.message)
    case .stopFailed:
      return .init(code: "subagent_stop_failed", message: error.message, retryable: true)
    case .shutDown:
      return .init(code: "subagent_scheduler_stopped", message: error.message, retryable: true)
    }
  }
}

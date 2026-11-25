import BridgeACP
import BridgeEmbeddedDSH
import BridgeServiceCore
import Foundation

extension ServiceEmbeddedDSHController {
  /// A returned engine error is a definite rejection only when the round was never recorded.
  /// An error after `round.start` can instead mean the session notice still needs recovery.
  func failRejectedDispatch(_ record: ServiceWorkbenchOperation, error: any Error) async throws
    -> Bool
  {
    guard case .some(.remote(_, _)) = error as? EmbeddedDSHRuntimeError, !record.cancelled,
      record.draft.kind == "subagents.control"
    else { return false }
    let frozen = try Self.decodeObject(record.draft.inputJSON)
    guard let dispatch = frozen["dispatch"]?.objectValue,
      dispatch["operation"]?.stringValue == "dispatch"
    else { return false }
    let receipt = try await dispatchReceipt(record, dispatch: dispatch)
    guard receipt["state"]?.stringValue == "notFound",
      let current = try await store.workbenchOperation(id: record.draft.operationID),
      !current.cancelled, !current.phase.isTerminal
    else { return false }
    _ = try await store.transitionWorkbenchOperation(
      id: current.draft.operationID, expectedVersion: current.version, phase: .failed,
      resultJSON: Self.json(operationError(error)))
    await publishOperation(current.draft.operationID)
    return true
  }

  /// Settles a hand-over to a connected agent (`dispatch`) whose outcome is unknown. The child does
  /// not exist before the hand-over, so there is nothing to look up in the child list; the round
  /// receipt says whether the Service recorded the request, under the root the request was issued
  /// for.
  ///
  /// A request that was recorded is dispatched to the engine once more: the engine recognises the
  /// round and only fills in what a crash may have cost (the child and the notice in the session).
  /// A request that never arrived is sent again within the operation's budget, like a prompt.
  func reconcileDispatchOperation(
    _ record: ServiceWorkbenchOperation, dispatch: [String: ACPJSONValue]
  ) async throws {
    let receipt = try await dispatchReceipt(record, dispatch: dispatch)
    guard receipt["state"]?.stringValue != "notFound" else {
      if try await mayResume(record), record.version <= 3 {
        _ = try await store.transitionWorkbenchOperation(
          id: record.draft.operationID, expectedVersion: record.version,
          phase: .recorded, confirmedUndispatched: true)
      }
      return
    }
    // A withdrawn hand-over has nothing left to write down.
    let result = record.cancelled ? receipt : try await dispatchOperation(record)
    try await acceptRecoveredOperation(record, result: result)
  }

  private func dispatchReceipt(
    _ record: ServiceWorkbenchOperation, dispatch: [String: ACPJSONValue]
  ) async throws -> ACPJSONValue {
    try await invoke(
      action: "subagents.receipt",
      payload: .object([
        "sessionId": .string(try Self.requiredString(dispatch, "sessionId")),
        "childId": .string(try Self.requiredString(dispatch, "childId")),
        "requestId": .string(record.draft.requestID),
      ]))
  }
}

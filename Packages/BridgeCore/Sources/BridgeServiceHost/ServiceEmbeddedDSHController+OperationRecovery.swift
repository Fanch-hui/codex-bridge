import BridgeACP
import BridgeEmbeddedDSH
import BridgeSecurity
import BridgeServiceApplication
import BridgeServiceCore
import Foundation

extension ServiceEmbeddedDSHController {
  func restoreOperations() async {
    do {
      let operations = try await store.workbenchOperations(unresolvedOnly: true, limit: 500)
      for operation in operations { scheduleOperation(operation.draft.operationID) }
      for binding in try await store.pendingWorkbenchProjectBindings() {
        do {
          let generation = try await store.workbenchGeneration(sessionID: binding.logicalSessionID)
          if generation.closed { continue }
          _ = try await bindProject([
            "sessionId": .string(binding.logicalSessionID),
            "projectID": .string(binding.projectID), "requestId": .string(binding.requestID),
            "toolCallId": .string(binding.toolCallID),
          ])
        } catch {
          await receive(
            EmbeddedDSHEvent(type: "operations.recoveryFailed", payload: operationError(error)))
        }
      }
    } catch {
      await receive(
        EmbeddedDSHEvent(type: "operations.recoveryFailed", payload: operationError(error)))
    }
  }

  func scheduleRecordedOperation(_ id: String) async {
    do {
      guard let record = try await store.workbenchOperation(id: id),
        record.phase == .recorded, !record.cancelled
      else { return }
      scheduleOperation(id)
    } catch {
      await receive(
        EmbeddedDSHEvent(type: "operations.recoveryFailed", payload: operationError(error)))
    }
  }

  func reconcileOperation(_ record: ServiceWorkbenchOperation) async throws {
    let id = record.draft.operationID
    guard !record.phase.isTerminal else { return }
    if record.cancelled, record.draft.kind == "subagents.control" {
      try await scheduleChildCancellationStop(record)
    }
    if record.phase == .recorded {
      scheduleOperation(id)
      return
    }
    if record.phase == .accepted {
      try await finishAcceptedOperation(record)
      return
    }
    if Self.webOperationKinds.contains(record.draft.kind) {
      if let result = try await application.reconcileWorkbenchTaskOperation(
        kind: record.draft.kind,
        operationID: id, inputJSON: record.draft.inputJSON)
      {
        let value = try Self.decodeObject(result)
        try await acceptRecoveredOperation(record, result: .object(value))
      } else if record.draft.kind == "workbench.resume" {
        try await recoverUndispatchedResume(record)
      }
      return
    }
    let frozen = try Self.decodeObject(record.draft.inputJSON)
    guard let dispatch = frozen["dispatch"]?.objectValue else { return }
    if record.draft.kind == "session.prompt", let nativeID = dispatch["sessionId"]?.stringValue {
      let receipt = try await invoke(
        action: "session.receipt",
        payload: .object([
          "sessionId": .string(nativeID), "requestId": .string(record.draft.requestID),
        ]))
      if receipt["state"]?.stringValue == "accepted" {
        if receipt["pending"]?.boolValue == true, try await mayResume(record) {
          _ = try await invoke(
            action: "session.resumePending",
            payload: .object([
              "sessionId": .string(nativeID), "requestId": .string(record.draft.requestID),
            ]))
        }
        try await acceptRecoveredOperation(
          record,
          result: .object([
            "accepted": .bool(true),
            "sessionId": .string(record.draft.sessionID ?? nativeID),
          ]))
      } else if receipt["state"]?.stringValue == "notFound", try await mayResume(record),
        record.version <= 3, frozen["legacyPending"]?.boolValue != true
      {
        // A second dispatch has a higher durable version and cannot restart this budget.
        _ = try await store.transitionWorkbenchOperation(
          id: id, expectedVersion: record.version,
          phase: .recorded, confirmedUndispatched: true)
      }
    } else if record.draft.kind == "subagents.control", let sessionID = record.draft.sessionID {
      if dispatch["operation"]?.stringValue == "cancelInput" {
        let result = try await dispatchChildInputCancellation(dispatch)
        try await acceptRecoveredOperation(record, result: result)
      } else {
        try await reconcileChildOperation(record, sessionID: sessionID, dispatch: dispatch)
      }
    }
  }

  /// A resume creates its task in one store transaction keyed by the operation ID, so no task
  /// proves the continuation never reached execution: it is dispatched once more with its
  /// original ID, and fails visibly once that budget is spent.
  private func recoverUndispatchedResume(_ record: ServiceWorkbenchOperation) async throws {
    if try await mayResume(record), record.version <= 3 {
      _ = try await store.transitionWorkbenchOperation(
        id: record.draft.operationID, expectedVersion: record.version,
        phase: .recorded, confirmedUndispatched: true)
      scheduleOperation(record.draft.operationID)
      return
    }
    try await failRecoveredChildOperation(
      record, code: "workbench_resume_not_dispatched",
      message: "The continuation did not start. Send it again.")
  }

  private func mayResume(_ record: ServiceWorkbenchOperation) async throws -> Bool {
    guard let current = try await store.workbenchOperation(id: record.draft.operationID),
      !current.cancelled, !current.phase.isTerminal
    else { return false }
    guard let sessionID = current.draft.sessionID else { return true }
    let generation = try await store.workbenchGeneration(sessionID: sessionID)
    return !generation.closed && generation.generation == current.generation
  }

  private func reconcileChildOperation(
    _ record: ServiceWorkbenchOperation, sessionID: String,
    dispatch: [String: ACPJSONValue]
  ) async throws {
    if dispatch["operation"]?.stringValue == "cancelInput" {
      do {
        let result = try await dispatchChildInputCancellation(dispatch)
        try await acceptRecoveredOperation(record, result: result)
      } catch ServiceStoreError.invalidArgument("embedded_dsh.cancellation_pending") {
        // Cancellation remains bound to the original input until its outcome is known.
      }
      return
    }
    guard dispatch["operation"]?.stringValue == "send",
      let childID = dispatch["childId"]?.stringValue,
      record.draft.childID == nil || record.draft.childID == childID
    else { return }
    let response = try await performAction(
      "subagents.list", payload: ["sessionId": .string(sessionID)])
    guard
      let item = response["items"]?.arrayValue?.first(where: {
        $0["childId"]?.stringValue == childID
      })
    else { return }
    if item["mode"]?.stringValue == "external" {
      let rootID = try await nativeSessionID(for: sessionID)
      if let text = dispatch["text"]?.stringValue {
        do {
          if let receipt = try await previousInputResult(
            [
              "requestID": .string(record.draft.requestID), "prompt": .string(text),
            ], rootID: rootID, childID: childID)
          {
            try await acceptRecoveredOperation(record, result: receipt)
            return
          }
        } catch ServiceStoreError.invalidArgument("embedded_dsh.input_outcome_unknown") {
          // The provider may have received this input; query the persisted Node receipt.
        }
      }
      if let input = try await store.embeddedDSHInput(
        parentSessionID: rootID, childID: childID, requestID: record.draft.requestID),
        let taskID = input.taskID
      {
        let receipt = try await reconciledSubagentSubmission(
          rootID: rootID, childID: childID, taskID: taskID)
        try await acceptRecoveredOperation(record, result: receipt)
        return
      }
      let receipt = try await invoke(
        action: "subagents.receipt",
        payload: .object([
          "sessionId": .string(rootID), "childId": .string(childID),
          "requestId": .string(record.draft.requestID),
        ]))
      switch receipt["state"]?.stringValue {
      case "accepted", "queued":
        var result = receipt.objectValue ?? [:]
        result["accepted"] = .bool(true)
        result["queued"] = .bool(receipt["state"]?.stringValue == "queued")
        try await acceptRecoveredOperation(record, result: .object(result))
      case "cancelled":
        try await acceptRecoveredOperation(
          record, result: .object(["accepted": .bool(false), "state": .string("cancelled")]))
      case "failed":
        try await failRecoveredChildOperation(
          record, code: "subagent_input_failed",
          message: receipt["error"]?.stringValue ?? "The queued subagent input failed.")
      case "unknown" where receipt["reason"]?.stringValue == "delivery_unknown":
        try await failRecoveredChildOperation(
          record, code: "subagent_delivery_unknown",
          message: "The subagent input delivery could not be confirmed.")
      case "notFound" where try await mayResume(record) && record.version <= 3:
        _ = try await store.transitionWorkbenchOperation(
          id: record.draft.operationID, expectedVersion: record.version,
          phase: .recorded, confirmedUndispatched: true)
      default:
        break
      }
    } else if let childSession = item["sessionId"]?.stringValue {
      let receipt = try await invoke(
        action: "session.receipt",
        payload: .object([
          "sessionId": .string(childSession), "requestId": .string(record.draft.requestID),
        ]))
      if receipt["state"]?.stringValue == "accepted" {
        try await acceptRecoveredOperation(record, result: .object(["accepted": .bool(true)]))
      }
    }
  }

  private func failRecoveredChildOperation(
    _ record: ServiceWorkbenchOperation, code: String, message: String
  ) async throws {
    guard let current = try await store.workbenchOperation(id: record.draft.operationID),
      !current.phase.isTerminal
    else { return }
    let safeMessage = OutboundContentSecurity.redactedSecrets(message, maximumUTF8Bytes: 4 * 1_024)
    _ = try await store.transitionWorkbenchOperation(
      id: current.draft.operationID, expectedVersion: current.version, phase: .failed,
      resultJSON: Self.json(
        .object([
          "code": .string(code), "message": .string(safeMessage),
          "failureReason": .string(safeMessage),
        ])))
    await publishOperation(current.draft.operationID)
  }

  private func acceptRecoveredOperation(
    _ record: ServiceWorkbenchOperation,
    result: ACPJSONValue
  ) async throws {
    let id = record.draft.operationID
    var current = try await store.workbenchOperation(id: id) ?? record
    guard !current.phase.isTerminal else { return }
    current = try await store.transitionWorkbenchOperation(
      id: id, expectedVersion: current.version,
      phase: .accepted, resultTargetID: result["taskID"]?.stringValue, resultJSON: Self.json(result)
    )
    try await finishAcceptedOperation(current)
  }

  func finishAcceptedOperation(_ record: ServiceWorkbenchOperation) async throws {
    if record.draft.kind == "session.prompt" {
      let frozen = try Self.decodeObject(record.draft.inputJSON)
      let references = frozen["dispatch"]?["attachmentRefs"]?.arrayValue ?? []
      if !references.isEmpty { try archiveAcceptedAttachments(references) }
    }
    let current = try await store.workbenchOperation(id: record.draft.operationID) ?? record
    guard current.phase == .accepted else { return }
    _ = try await store.transitionWorkbenchOperation(
      id: current.draft.operationID,
      expectedVersion: current.version, phase: current.cancelled ? .cancelled : .completed)
    await publishOperation(current.draft.operationID)
  }

  func operationFailed(_ id: String, error: any Error) async {
    do {
      guard var record = try await store.workbenchOperation(id: id), !record.phase.isTerminal else {
        return
      }
      if record.phase == .accepted, record.draft.kind == "session.prompt" {
        await receive(
          EmbeddedDSHEvent(
            type: "operations.attachmentArchiveFailed", payload: operationError(error)))
        return
      }
      if record.draft.kind == "session.stop", record.phase != .recorded {
        if record.phase == .accepted {
          await receive(
            EmbeddedDSHEvent(
              type: "operations.reconciliationPending", payload: operationError(error)))
          return
        }
        if record.phase != .unknown {
          _ = try await store.transitionWorkbenchOperation(
            id: id, expectedVersion: record.version,
            phase: .unknown)
        }
        await publishOperation(id)
        return
      }
      let definiteRejection: Bool
      if case ServiceStoreError.invalidArgument("workbench.operation_binding_changed") = error {
        definiteRejection = true
      } else {
        definiteRejection =
          record.phase == .recorded || error is WorkbenchTaskOperationNotDispatched
      }
      if !definiteRejection {
        do { try await reconcileOperation(record) } catch {
          await receive(
            EmbeddedDSHEvent(
              type: "operations.reconciliationPending", payload: operationError(error)))
        }
        record = try await store.workbenchOperation(id: id) ?? record
        if record.phase.isTerminal || record.phase == .recorded { return }
      }
      if definiteRejection || record.phase != .unknown {
        _ = try await store.transitionWorkbenchOperation(
          id: id, expectedVersion: record.version,
          phase: definiteRejection ? .failed : .unknown,
          resultJSON: Self.json(operationError(error)))
      }
      await publishOperation(id)
    } catch {
      await receive(
        EmbeddedDSHEvent(type: "operations.recoveryFailed", payload: operationError(error)))
    }
  }

  func publishOperation(_ id: String) async {
    await receive(
      EmbeddedDSHEvent(type: "operations.changed", payload: .object(["operationID": .string(id)])))
  }

  private func operationError(_ error: any Error) -> ACPJSONValue {
    let failure = BridgeServiceRequestController.map(error)
    return .object(["code": .string(failure.code), "message": .string(failure.message)])
  }
}

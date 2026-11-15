import BridgeACP
import BridgeServiceCore
import Crypto
import Foundation

extension ServiceEmbeddedDSHController {
  /// Drives a stop to its end. When a stop request failed and the engine still reports the root
  /// running with no stop in flight, the request is sent again, a bounded number of times and
  /// with growing pauses (`stopResendDelays`); the pauses hold no admission slot. After the last
  /// resend the operation is reported unconfirmed, as it always was when a stop could not be
  /// confirmed.
  func runStopOperation(_ initial: ServiceWorkbenchOperation) async throws {
    let id = initial.draft.operationID
    var passes = 0
    while case .rootRunning(let resendable, let resends) = try await advanceStopOperation(id),
      resendable
    {
      // The stored count bounds the resends overall; `passes` bounds this run if a resend ever
      // returns without being counted.
      guard resends < stopResendDelays.count, passes < stopResendDelays.count else {
        throw WorkbenchStopUnconfirmed()
      }
      passes += 1
      try await Task.sleep(for: stopResendDelays[resends])
      guard !isShuttingDown else { return }
      try await resendStop(operationID: id)
    }
  }

  private func advanceStopOperation(_ id: String) async throws -> StopProgress {
    await operationAdmission.acquire(priority: true)
    defer { operationAdmission.release(priority: true) }
    guard var record = try await store.workbenchOperation(id: id),
      !record.phase.isTerminal, let sessionID = record.draft.sessionID
    else { return .settled }
    var generation = try await store.workbenchGeneration(sessionID: sessionID)
    if generation.generation != record.generation {
      try await finishObsoleteStop(record)
      return .settled
    }
    if record.phase == .recorded {
      record = try await sendInitialStop(record, sessionID: sessionID, generation: generation)
      guard !record.phase.isTerminal else { return .settled }
    }
    let gate = operationGate(for: record)
    await gate.acquire()
    defer { gate.release() }
    record = try await store.workbenchOperation(id: record.draft.operationID) ?? record
    guard !record.phase.isTerminal else { return .settled }
    generation = try await store.workbenchGeneration(sessionID: sessionID)
    guard generation.generation == record.generation else {
      try await finishObsoleteStop(record)
      return .settled
    }
    if record.phase != .accepted {
      guard generation.closed else { return .settled }
      let step = try await confirmOrDispatchStop(record, sessionID: sessionID)
      guard let confirmed = step.record else { return step.progress }
      record = confirmed
      guard !record.phase.isTerminal else { return .settled }
    }
    try await completeStop(record, sessionID: sessionID)
    return .settled
  }

  /// The first stop request: closes the generation and asks the engine to stop the root. A
  /// failure here leaves the operation unconfirmed (see `operationFailed`).
  private func sendInitialStop(
    _ recorded: ServiceWorkbenchOperation, sessionID: String, generation: ServiceWorkbenchGeneration
  ) async throws -> ServiceWorkbenchOperation {
    if !generation.closed {
      try await store.closeWorkbenchGeneration(
        sessionID: sessionID, generation: recorded.generation)
    }
    bindingTasks[sessionID]?.cancel()
    var record = try await store.transitionWorkbenchOperation(
      id: recorded.draft.operationID, expectedVersion: recorded.version, phase: .dispatching)
    let nativeID = try await nativeSessionID(for: sessionID)
    _ = try await stopSession(["sessionId": .string(nativeID)], releasesExecution: false)
    record = try await store.workbenchOperation(id: record.draft.operationID) ?? record
    guard !record.phase.isTerminal else { return record }
    return try await store.transitionWorkbenchOperation(
      id: record.draft.operationID, expectedVersion: record.version, phase: .dispatching,
      resultJSON: try Self.json(.object(["stopStage": .string("initialStopped")])))
  }

  /// Either confirms that the root stopped, or dispatches the final barrier once the initial
  /// request is known to have been delivered. A nil record means the root is still running.
  private func confirmOrDispatchStop(_ operation: ServiceWorkbenchOperation, sessionID: String)
    async throws -> (record: ServiceWorkbenchOperation?, progress: StopProgress)
  {
    var record = operation
    if try Self.stopState(record).stage != "initialStopped" {
      let nativeID = try await nativeSessionID(for: sessionID)
      let status = try await invoke(
        action: "session.stopStatus", payload: .object(["sessionId": .string(nativeID)]))
      // An engine that does not report `stopping` never gets a resend.
      guard status["stopped"]?.boolValue == true else {
        let resendable = status["stopping"]?.boolValue == false
        return (
          nil, .rootRunning(resendable: resendable, resends: try Self.stopState(record).resends)
        )
      }
      try await finishStoppedExecution(sessionID: nativeID)
      record = try await store.transitionWorkbenchOperation(
        id: record.draft.operationID, expectedVersion: record.version, phase: .accepted,
        resultJSON: try Self.json(.object(["accepted": .bool(true)])))
      return (record, .settled)
    }
    record = try await store.transitionWorkbenchOperation(
      id: record.draft.operationID, expectedVersion: record.version, phase: record.phase,
      resultJSON: try Self.json(.object(["stopStage": .string("barrierDispatched")])))
    let result = try await dispatchOperation(record)
    record = try await store.workbenchOperation(id: record.draft.operationID) ?? record
    guard !record.phase.isTerminal else { return (record, .settled) }
    record = try await store.transitionWorkbenchOperation(
      id: record.draft.operationID, expectedVersion: record.version,
      phase: .accepted, resultJSON: try Self.json(result))
    return (record, .settled)
  }

  private func completeStop(_ operation: ServiceWorkbenchOperation, sessionID: String) async throws
  {
    var record = operation
    let generation = try await store.workbenchGeneration(sessionID: sessionID)
    if generation.generation == record.generation, generation.closed {
      _ = try await store.advanceWorkbenchGeneration(
        sessionID: sessionID, expectedGeneration: record.generation)
    }
    record = try await store.workbenchOperation(id: record.draft.operationID) ?? record
    if record.phase == .accepted {
      _ = try await store.transitionWorkbenchOperation(
        id: record.draft.operationID, expectedVersion: record.version, phase: .completed)
    }
    await publishOperation(record.draft.operationID)
  }

  private func finishStoppedExecution(sessionID: String) async throws {
    if let projectID = try await storedProjectID(for: sessionID) {
      try await application.stopEmbeddedDSHExecution(
        sessionID: sessionID, projectID: .init(rawValue: projectID))
    }
    await application.finishUnscopedWorkbenchExecution(
      sessionID: nativeLogicalIDs[sessionID] ?? sessionID)
    try await clearWorkspaceRequest(sessionID)
  }

  private func finishObsoleteStop(_ record: ServiceWorkbenchOperation) async throws {
    let phase: ServiceWorkbenchOperationPhase = record.phase == .accepted ? .completed : .cancelled
    _ = try await store.transitionWorkbenchOperation(
      id: record.draft.operationID, expectedVersion: record.version, phase: phase)
    await publishOperation(record.draft.operationID)
  }

  func cancelOperation(_ id: String) async throws -> ACPJSONValue {
    guard let initial = try await store.workbenchOperation(id: id) else {
      throw ServiceStoreError.invalidArgument("operation.notFound")
    }
    guard !initial.phase.isTerminal, initial.draft.kind != "session.stop" else {
      return try operationEnvelope([initial])
    }
    if initial.draft.kind == "session.prompt", let sessionID = initial.draft.sessionID {
      try await scheduleCancellationStop(initial, sessionID: sessionID)
    }
    let record = try await store.cancelWorkbenchOperation(id: id)
    if !record.phase.isTerminal, record.draft.kind == "subagents.control" {
      try await scheduleChildCancellationStop(record)
    } else if !record.phase.isTerminal, Self.webOperationKinds.contains(record.draft.kind),
      let targetID = record.resultTargetID ?? record.draft.targetID
    {
      await operationAdmission.acquire(priority: true)
      defer { operationAdmission.release(priority: true) }
      try await application.serviceStopTask(
        taskID: targetID, deadline: .now.advanced(by: .seconds(40)))
    }
    return try operationEnvelope([try await store.workbenchOperation(id: id) ?? record])
  }

  private func scheduleCancellationStop(_ record: ServiceWorkbenchOperation, sessionID: String)
    async throws
  {
    let generation = try await store.workbenchGeneration(sessionID: sessionID)
    guard generation.generation == record.generation else { return }
    if generation.closed {
      let operations = try await store.workbenchOperations(
        sessionID: sessionID, unresolvedOnly: true, limit: 500)
      if let stop = operations.first(where: {
        $0.draft.kind == "session.stop" && $0.generation == record.generation
      }) {
        scheduleOperation(stop.draft.operationID)
      }
      return
    }
    let stopID = Self.cancellationStopID(record.draft.operationID)
    do {
      let result = try await registerOperation(
        [
          "operationID": .string(stopID), "requestID": .string(stopID),
          "kind": .string("session.stop"), "sessionID": .string(sessionID),
          "input": .object(["sessionId": .string(sessionID)]),
        ], expectedGeneration: record.generation)
      scheduleOperation(result.operation.draft.operationID)
    } catch ServiceStoreError.invalidArgument("operation.generationClosed") {
      try await scheduleCancellationStop(record, sessionID: sessionID)
    }
  }

  func scheduleChildCancellationStop(_ record: ServiceWorkbenchOperation) async throws {
    let frozen = try Self.decodeObject(record.draft.inputJSON)
    guard let dispatch = frozen["dispatch"]?.objectValue,
      let sessionID = record.draft.sessionID, let childID = dispatch["childId"]?.stringValue
    else { throw ServiceStoreError.invalidArgument("workbench.operation_input") }
    guard dispatch["operation"]?.stringValue == "send" else { return }
    let generation = try await store.workbenchGeneration(sessionID: sessionID)
    guard !generation.closed, generation.generation == record.generation else { return }
    let stopID = Self.cancellationStopID(record.draft.operationID)
    do {
      let result = try await registerOperation(
        [
          "operationID": .string(stopID), "requestID": .string(stopID),
          "kind": .string("subagents.control"), "sessionID": .string(sessionID),
          "childID": .string(childID),
          "input": .object([
            "sessionId": .string(sessionID), "childId": .string(childID),
            "operation": .string("cancelInput"),
            "targetRequestId": .string(record.draft.requestID),
            "requestId": .string(stopID),
          ]),
        ], expectedGeneration: record.generation)
      scheduleOperation(result.operation.draft.operationID)
    } catch ServiceStoreError.invalidArgument("operation.generationClosed") {
      // A root stop owns cleanup once this generation closes.
    }
  }

  private static func cancellationStopID(_ operationID: String) -> String {
    "cancel-"
      + SHA256.hash(data: Data(operationID.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

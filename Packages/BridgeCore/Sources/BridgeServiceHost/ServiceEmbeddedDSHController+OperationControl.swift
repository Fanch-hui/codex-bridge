import BridgeACP
import BridgeServiceCore
import Crypto
import Foundation

extension ServiceEmbeddedDSHController {
  func runStopOperation(_ initial: ServiceWorkbenchOperation) async throws {
    await operationAdmission.acquire(priority: true)
    defer { operationAdmission.release(priority: true) }
    guard var record = try await store.workbenchOperation(id: initial.draft.operationID),
      !record.phase.isTerminal, let sessionID = record.draft.sessionID
    else { return }
    var generation = try await store.workbenchGeneration(sessionID: sessionID)
    if generation.generation != record.generation {
      try await finishObsoleteStop(record)
      return
    }
    if record.phase == .recorded {
      if !generation.closed {
        try await store.closeWorkbenchGeneration(
          sessionID: sessionID, generation: record.generation)
      }
      bindingTasks[sessionID]?.cancel()
      record = try await store.transitionWorkbenchOperation(
        id: record.draft.operationID, expectedVersion: record.version, phase: .dispatching)
      let nativeID = try await nativeSessionID(for: sessionID)
      _ = try await stopSession(["sessionId": .string(nativeID)], releasesExecution: false)
      record = try await store.workbenchOperation(id: record.draft.operationID) ?? record
      guard !record.phase.isTerminal else { return }
      record = try await store.transitionWorkbenchOperation(
        id: record.draft.operationID, expectedVersion: record.version, phase: .dispatching,
        resultJSON: try Self.json(.object(["stopStage": .string("initialStopped")])))
    }
    let gate = operationGate(for: record)
    await gate.acquire()
    defer { gate.release() }
    record = try await store.workbenchOperation(id: record.draft.operationID) ?? record
    guard !record.phase.isTerminal else { return }
    generation = try await store.workbenchGeneration(sessionID: sessionID)
    guard generation.generation == record.generation else {
      try await finishObsoleteStop(record)
      return
    }
    if record.phase != .accepted {
      var stage: String?
      if let json = record.resultJSON {
        stage = try Self.decodeObject(json)["stopStage"]?.stringValue
      }
      guard generation.closed else { return }
      if stage != "initialStopped" {
        let nativeID = try await nativeSessionID(for: sessionID)
        let status = try await invoke(
          action: "session.stopStatus",
          payload: .object(["sessionId": .string(nativeID)]))
        guard status["stopped"]?.boolValue == true else { return }
        try await finishStoppedExecution(sessionID: nativeID)
        record = try await store.transitionWorkbenchOperation(
          id: record.draft.operationID,
          expectedVersion: record.version, phase: .accepted,
          resultJSON: try Self.json(.object(["accepted": .bool(true)])))
      } else {
        record = try await store.transitionWorkbenchOperation(
          id: record.draft.operationID, expectedVersion: record.version, phase: record.phase,
          resultJSON: try Self.json(.object(["stopStage": .string("barrierDispatched")])))
        let result = try await dispatchOperation(record)
        record = try await store.workbenchOperation(id: record.draft.operationID) ?? record
        guard !record.phase.isTerminal else { return }
        record = try await store.transitionWorkbenchOperation(
          id: record.draft.operationID, expectedVersion: record.version,
          phase: .accepted, resultJSON: try Self.json(result))
      }
    }
    generation = try await store.workbenchGeneration(sessionID: sessionID)
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

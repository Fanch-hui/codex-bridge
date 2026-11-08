import BridgeACP
import BridgeServiceApplication
import BridgeServiceCore
import Foundation

extension ServiceEmbeddedDSHController {
  static let durableActions: Set<String> = [
    "session.prompt", "session.stop", "subagents.control",
    "plugins.install", "plugins.update",
  ]
  static let webOperationKinds: Set<String> = [
    "workbench.resume", "workbench.steer", "handoff.submit",
  ]

  func operationAction(_ action: String, payload: [String: ACPJSONValue]) async throws
    -> ACPJSONValue
  {
    switch action {
    case "operations.submit":
      let record = try await registerOperation(payload)
      scheduleOperation(record.operation.draft.operationID)
      return try operationEnvelope([record.operation], created: record.created)
    case "operations.read":
      let ids = payload["operationIDs"]?.arrayValue?.compactMap(\.stringValue)
      if ids?.isEmpty == true { return .object(["operations": .array([])]) }
      let records = try await store.workbenchOperations(
        ids: ids,
        sessionID: payload["sessionID"]?.stringValue,
        unresolvedOnly: payload["unresolvedOnly"]?.boolValue ?? false,
        limit: min(500, max(1, payload["limit"]?.intValue ?? 100)))
      for record in records where !record.phase.isTerminal {
        scheduleOperation(record.draft.operationID)
      }
      return try operationEnvelope(records)
    case "operations.reconcile":
      let id = try Self.requiredString(payload, "operationID")
      guard try await store.workbenchOperation(id: id) != nil else {
        return .object(["operations": .array([]), "outcome": .string("notFound")])
      }
      if operationTasks[id] == nil { scheduleOperation(id) }
      let updated = try await store.workbenchOperation(id: id)
      return try operationEnvelope(updated.map { [$0] } ?? [])
    case "operations.cancel":
      let id = try Self.requiredString(payload, "operationID")
      return try await cancelOperation(id)
    default: throw ServiceStoreError.invalidArgument("workbench.operation_action")
    }
  }

  func registerOperation(_ payload: [String: ACPJSONValue], expectedGeneration: Int64? = nil)
    async throws
    -> ServiceWorkbenchOperationRegistration
  {
    let id = try Self.requiredString(payload, "operationID")
    let kind = try Self.requiredString(payload, "kind")
    guard Self.durableActions.contains(kind) || Self.webOperationKinds.contains(kind),
      let request = payload["input"]?.objectValue
    else { throw ServiceStoreError.invalidArgument("workbench.operation_input") }
    if let previous = try await store.workbenchOperation(id: id) {
      let stored = try Self.decodeObject(previous.draft.inputJSON)
      guard previous.draft.kind == kind,
        expectedGeneration == nil || expectedGeneration == previous.generation,
        Self.canonicalJSON(.object(request))
          == Self.canonicalJSON(stored["request"] ?? .object(stored))
      else { throw ServiceStoreError.invalidArgument("operation.idempotencyConflict") }
      return try await store.registerWorkbenchOperation(
        previous.draft, generation: previous.generation)
    }
    let sessionID =
      payload["sessionID"]?.stringValue ?? request["sessionId"]?.stringValue
      ?? request["taskID"]?.stringValue
    if ["session.prompt", "session.stop", "subagents.control"].contains(kind),
      sessionID?.isEmpty != false
    {
      throw ServiceStoreError.invalidArgument("workbench.operation_session")
    }
    let generation: Int64
    if let expectedGeneration {
      generation = expectedGeneration
    } else if let sessionID {
      generation = try await store.workbenchGeneration(sessionID: sessionID).generation
    } else {
      generation = 0
    }
    let inputJSON: String
    let projectID: String?
    if Self.webOperationKinds.contains(kind) {
      inputJSON = try await application.prepareWorkbenchTaskOperation(
        kind: kind,
        inputJSON: Self.json(.object(request)))
      projectID = nil
    } else {
      var dispatch = request
      var frozen: [String: ACPJSONValue] = ["request": .object(request)]
      if payload["legacyPending"]?.boolValue == true { frozen["legacyPending"] = .bool(true) }
      if let sessionID {
        let nativeID = try await nativeSessionID(for: sessionID)
        dispatch["sessionId"] = .string(nativeID)
        projectID = try await storedProjectID(for: nativeID)
        if kind == "session.prompt" {
          if let projectID { _ = try await registeredProject(projectID) }
          dispatch = try await freezePromptAttachments(dispatch, sessionID: nativeID)
          frozen["bindingSnapshot"] = try await invoke(
            action: "session.bindingSnapshot",
            payload: .object(["sessionId": .string(nativeID)]))
        }
      } else {
        projectID = nil
      }
      dispatch["requestId"] = .string(payload["requestID"]?.stringValue ?? id)
      frozen["dispatch"] = .object(dispatch)
      inputJSON = Self.canonicalJSON(.object(frozen))
    }
    let draft = ServiceWorkbenchOperationDraft(
      operationID: id, kind: kind, sessionID: sessionID,
      childID: payload["childID"]?.stringValue, projectID: projectID,
      targetID: payload["targetID"]?.stringValue ?? request["taskID"]?.stringValue,
      requestID: payload["requestID"]?.stringValue ?? id, inputJSON: inputJSON)
    let registration = try await store.registerWorkbenchOperation(draft, generation: generation)
    if kind == "session.stop", let sessionID { bindingTasks[sessionID]?.cancel() }
    if registration.created, payload["legacyPending"]?.boolValue == true {
      var imported = try await store.transitionWorkbenchOperation(
        id: id,
        expectedVersion: registration.operation.version, phase: .dispatching)
      imported = try await store.transitionWorkbenchOperation(
        id: id,
        expectedVersion: imported.version, phase: .unknown)
      return ServiceWorkbenchOperationRegistration(operation: imported, created: true)
    }
    return registration
  }

  func performDurableAction(_ action: String, payload: [String: ACPJSONValue]) async throws
    -> ACPJSONValue
  {
    let requestID =
      payload["requestId"]?.stringValue ?? payload["requestID"]?.stringValue ?? UUID().uuidString
    let result = try await registerOperation([
      "operationID": .string(requestID),
      "requestID": .string(requestID), "kind": .string(action), "input": .object(payload),
    ])
    scheduleOperation(requestID)
    await operationTasks[requestID]?.value
    let record = try await store.workbenchOperation(id: requestID) ?? result.operation
    if [.recorded, .dispatching, .unknown].contains(record.phase) {
      return .object([
        "operationID": .string(requestID), "accepted": .bool(false),
        "state": .string(record.phase.rawValue),
      ])
    }
    if let json = record.resultJSON {
      let response = try Self.decodeObject(json)
      if record.phase == .failed {
        throw ServiceStoreError.invalidArgument(
          response["message"]?.stringValue ?? "workbench.operation_failed")
      }
      return .object(response)
    }
    return .object([
      "operationID": .string(requestID), "accepted": .bool(false),
      "state": .string(record.phase.rawValue),
    ])
  }

  func scheduleOperation(_ id: String) {
    guard operationTasks[id] == nil, !isShuttingDown else { return }
    operationTasks[id] = Task { await self.runOperation(id) }
  }

  private func runOperation(_ id: String) async {
    defer {
      operationTasks.removeValue(forKey: id)
      Task { await self.scheduleRecordedOperation(id) }
    }
    do {
      while isApplyingConfiguration { try await Task.sleep(for: .milliseconds(30)) }
      guard var record = try await store.workbenchOperation(id: id), !record.phase.isTerminal else {
        return
      }
      if record.draft.kind == "session.stop" {
        try await runStopOperation(record)
        return
      }
      let gate = operationGate(for: record)
      await gate.acquire()
      defer { gate.release() }
      await operationAdmission.acquire(priority: false)
      defer { operationAdmission.release(priority: false) }
      guard let current = try await store.workbenchOperation(id: id), !current.phase.isTerminal
      else { return }
      record = current
      if record.phase != .recorded {
        try await reconcileOperation(record)
        return
      }
      guard !record.cancelled, !isShuttingDown else { return }
      if let sessionID = record.draft.sessionID {
        let generation = try await store.workbenchGeneration(sessionID: sessionID)
        guard !generation.closed, generation.generation == record.generation else { return }
      }
      record = try await store.transitionWorkbenchOperation(
        id: id, expectedVersion: record.version, phase: .dispatching)
      let result = try await dispatchOperation(record)
      record = try await store.workbenchOperation(id: id) ?? record
      guard !record.phase.isTerminal else { return }
      let resultJSON = try Self.json(result)
      record = try await store.transitionWorkbenchOperation(
        id: id, expectedVersion: record.version,
        phase: .accepted, resultTargetID: result["taskID"]?.stringValue, resultJSON: resultJSON)
      try await finishAcceptedOperation(record)
    } catch {
      await operationFailed(id, error: error)
    }
  }

  func operationGate(for record: ServiceWorkbenchOperation) -> AsyncMutex {
    let key = record.draft.sessionID ?? record.draft.operationID
    let gate = operationGates[key] ?? AsyncMutex()
    operationGates[key] = gate
    return gate
  }

  func dispatchOperation(_ record: ServiceWorkbenchOperation) async throws -> ACPJSONValue {
    if Self.webOperationKinds.contains(record.draft.kind) {
      return .object(
        try Self.decodeObject(
          await application.performWorkbenchTaskOperation(
            kind: record.draft.kind, operationID: record.draft.operationID,
            inputJSON: record.draft.inputJSON)))
    }
    let frozen = try Self.decodeObject(record.draft.inputJSON)
    guard var dispatch = frozen["dispatch"]?.objectValue else {
      throw ServiceStoreError.invalidArgument("workbench.operation_input")
    }
    if let expected = frozen["bindingSnapshot"], let id = dispatch["sessionId"]?.stringValue {
      let actual: ACPJSONValue
      do {
        if let projectID = record.draft.projectID { _ = try await registeredProject(projectID) }
        actual = try await invoke(
          action: "session.bindingSnapshot", payload: .object(["sessionId": .string(id)]))
      } catch { throw WorkbenchTaskOperationNotDispatched(cause: error) }
      guard Self.canonicalJSON(actual) == Self.canonicalJSON(expected) else {
        throw ServiceStoreError.invalidArgument("workbench.operation_binding_changed")
      }
    }
    if record.draft.kind == "subagents.control", dispatch["operation"]?.stringValue == "cancelInput"
    {
      return try await dispatchChildInputCancellation(dispatch)
    }
    dispatch["requestId"] = .string(record.draft.requestID)
    return try await performAction(record.draft.kind, payload: dispatch, tracksOperation: false)
  }

  func dispatchChildInputCancellation(_ dispatch: [String: ACPJSONValue]) async throws
    -> ACPJSONValue
  {
    let response = try await invoke(
      action: "subagents.cancelInput",
      payload: .object([
        "sessionId": .string(Self.requiredString(dispatch, "sessionId")),
        "childId": .string(Self.requiredString(dispatch, "childId")),
        "requestId": .string(Self.requiredString(dispatch, "targetRequestId")),
      ]))
    if response["state"]?.stringValue == "unknown" {
      throw ServiceStoreError.invalidArgument("embedded_dsh.cancellation_pending")
    }
    return response
  }

  func operationEnvelope(_ records: [ServiceWorkbenchOperation], created: Bool? = nil) throws
    -> ACPJSONValue
  {
    let projected = records.map { record -> ACPJSONValue in
      var item: [String: ACPJSONValue] = [
        "operationID": .string(record.draft.operationID), "kind": .string(record.draft.kind),
        "requestID": .string(record.draft.requestID), "phase": .string(record.phase.rawValue),
        "cancelled": .bool(record.cancelled), "version": .integer(record.version),
        "generation": .integer(record.generation),
      ]
      if let id = record.draft.sessionID { item["sessionID"] = .string(id) }
      if let id = record.draft.childID { item["childID"] = .string(id) }
      if let id = record.draft.targetID { item["targetID"] = .string(id) }
      if let id = record.resultTargetID { item["resultTargetID"] = .string(id) }
      if let json = record.resultJSON { item["resultJSON"] = .string(json) }
      return .object(item)
    }
    var response: [String: ACPJSONValue] = ["operations": .array(projected)]
    if let created { response["created"] = .bool(created) }
    return .object(response)
  }

  static func decodeObject(_ json: String) throws -> [String: ACPJSONValue] {
    guard let value = try JSONDecoder().decode(ACPJSONValue.self, from: Data(json.utf8)).objectValue
    else {
      throw ServiceStoreError.invalidArgument("workbench.json")
    }
    return value
  }

  static func canonicalJSON(_ value: ACPJSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
  }
}

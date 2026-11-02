import BridgeACP
import BridgeDomain
import BridgeServiceCore
import Foundation

extension ServiceEmbeddedDSHController {
  func nativeSessionID(for id: String) async throws -> String {
    if let conversation = try await store.workbenchConversation(logicalSessionID: id) {
      nativeLogicalIDs[conversation.nativeSessionID] = id
      return conversation.nativeSessionID
    }
    try await authorizeSession(id, requiresProject: false)
    return id
  }

  func authorizeSession(_ id: String, requiresProject: Bool) async throws {
    if requiresProject {
      _ = try await project(for: id)
      return
    }
    if try await store.workbenchConversation(logicalSessionID: id) != nil { return }
    if try await store.workbenchConversation(nativeSessionID: id) != nil { return }
    if try await storedProjectID(for: id) != nil { return }
    throw ServiceStoreError.invalidArgument("embedded_dsh.session")
  }

  func resolveSession(_ payload: [String: ACPJSONValue]) async throws -> ACPJSONValue {
    let id = try Self.requiredString(payload, "sessionId")
    var conversation = try await store.workbenchConversation(logicalSessionID: id)
    if conversation == nil {
      conversation = try await store.workbenchConversation(nativeSessionID: id)
    }
    if let conversation {
      return .object([
        "sessionId": .string(conversation.logicalSessionID),
        "projectID": conversation.projectID.map(ACPJSONValue.string) ?? .null,
        "scope": .string(conversation.projectID == nil ? "chatOnly" : "project"),
      ])
    }
    let project = try await project(for: id)
    return .object([
      "sessionId": .string(id), "projectID": .string(project.id.rawValue),
      "scope": .string("project"),
    ])
  }

  func synchronizeSessionScope(_ id: String) async throws {
    let projectID = try await storedProjectID(for: id)
    var payload: [String: ACPJSONValue] = [
      "sessionId": .string(id),
      "scope": .string(projectID == nil ? "chatOnly" : "project"),
    ]
    if let projectID, let project = try await projects.project(id: .init(rawValue: projectID)) {
      payload["cwd"] = .string(project.root.canonicalPath)
    }
    _ = try await invoke(action: "session.scope", payload: .object(payload))
  }

  func loadConversationMappings() async throws {
    var cursor: ServiceWorkbenchConversationCursor?
    repeat {
      let page = try await store.workbenchConversations(limit: 500, before: cursor)
      for conversation in page {
        nativeLogicalIDs[conversation.nativeSessionID] = conversation.logicalSessionID
        if let projectID = conversation.projectID {
          sessionProjects[conversation.nativeSessionID] = projectID
        }
      }
      guard let last = page.last, page.count == 500 else { break }
      cursor = ServiceWorkbenchConversationCursor(
        updatedAt: last.updatedAt,
        logicalSessionID: last.logicalSessionID)
    } while !isShuttingDown
  }

  func bindProject(_ payload: [String: ACPJSONValue]) async throws -> ACPJSONValue {
    let id = try Self.requiredString(payload, "sessionId")
    let projectID = try Self.requiredString(payload, "projectID")
    _ = try await registeredProject(projectID)
    guard let conversation = try await store.workbenchConversation(logicalSessionID: id) else {
      throw ServiceStoreError.invalidArgument("workbench.session")
    }
    if let bound = conversation.projectID {
      guard bound == projectID else {
        throw ServiceStoreError.invalidArgument("workbench.session_scope")
      }
      return .object(["sessionId": .string(id), "projectID": .string(bound)])
    }
    if let task = bindingTasks[id] { return try await task.value }
    let requestID = payload["requestId"]?.stringValue ?? UUID().uuidString
    let previous = try await store.workbenchProjectBinding(logicalSessionID: id)
    if previous?.phase == .cancelled, previous?.requestID == requestID { throw CancellationError() }
    let targetID = previous?.phase != .cancelled ? previous?.targetNativeSessionID : nil
    let binding = try await store.prepareWorkbenchProjectBinding(
      logicalSessionID: id,
      targetNativeSessionID: targetID ?? UUID().uuidString, projectID: projectID,
      requestID: requestID, toolCallID: payload["toolCallId"]?.stringValue ?? "workspace")
    let task = Task { try await self.driveProjectBinding(binding) }
    bindingTasks[id] = task
    defer { bindingTasks.removeValue(forKey: id) }
    return try await task.value
  }

  private func driveProjectBinding(_ initial: ServiceWorkbenchBinding) async throws -> ACPJSONValue
  {
    let logicalID = initial.logicalSessionID
    let project = try await registeredProject(initial.projectID)
    var binding = initial
    let generation = try await store.workbenchGeneration(sessionID: logicalID)
    guard !generation.closed else { throw CancellationError() }
    let request: [String: ACPJSONValue] = [
      "sessionId": .string(binding.sourceNativeSessionID),
      "targetSessionId": .string(binding.targetNativeSessionID),
      "cwd": .string(project.root.canonicalPath), "scope": .string("project"),
      "requestId": .string(binding.requestID), "toolCallId": .string(binding.toolCallID),
    ]
    if binding.phase == .prepared {
      let result = try await invoke(action: "session.bindProject", payload: .object(request))
      let boundary = result["sourceBoundarySeq"]?.intValue ?? result["boundarySeq"]?.intValue
      guard let boundary else {
        throw ServiceStoreError.invalidArgument("workbench.binding_boundary")
      }
      binding = try await store.advanceWorkbenchProjectBinding(
        logicalSessionID: logicalID,
        expectedVersion: binding.version, phase: .oldStopped, boundarySeq: Int64(boundary))
    }
    try await checkBindingGeneration(logicalID, generation: generation.generation)
    if binding.phase == .oldStopped {
      _ = try await invoke(action: "session.bindProject", payload: .object(request))
      try await bindSession(binding.targetNativeSessionID, projectID: initial.projectID)
      nativeLogicalIDs[binding.targetNativeSessionID] = logicalID
      binding = try await store.advanceWorkbenchProjectBinding(
        logicalSessionID: logicalID,
        expectedVersion: binding.version, phase: .segmentCreated)
    }
    try await checkBindingGeneration(logicalID, generation: generation.generation)
    if binding.phase == .segmentCreated {
      _ = try await invoke(
        action: "session.continueProject",
        payload: .object([
          "sessionId": .string(binding.targetNativeSessionID),
          "sourceSessionId": .string(binding.sourceNativeSessionID),
          "requestId": .string(binding.requestID),
        ]))
      binding = try await store.advanceWorkbenchProjectBinding(
        logicalSessionID: logicalID,
        expectedVersion: binding.version, phase: .continuationEnqueued)
    }
    try await checkBindingGeneration(logicalID, generation: generation.generation)
    if binding.phase == .continuationEnqueued {
      _ = try await store.advanceWorkbenchProjectBinding(
        logicalSessionID: logicalID,
        expectedVersion: binding.version, phase: .committed)
    }
    nativeLogicalIDs[binding.targetNativeSessionID] = logicalID
    try await clearWorkspaceRequest(logicalID)
    return .object([
      "sessionId": .string(logicalID),
      "projectID": .string(initial.projectID), "scope": .string("project"),
    ])
  }

  private func checkBindingGeneration(_ id: String, generation: Int64) async throws {
    try Task.checkCancellation()
    let current = try await store.workbenchGeneration(sessionID: id)
    guard !current.closed, current.generation == generation else { throw CancellationError() }
  }

  func stopProjectBinding(_ logicalID: String, releasesExecution: Bool) async throws {
    bindingTasks[logicalID]?.cancel()
    guard let binding = try await store.workbenchProjectBinding(logicalSessionID: logicalID),
      binding.phase != .committed, binding.phase != .cancelled
    else { return }
    let result = try await invoke(
      action: "session.cancelBinding",
      payload: .object([
        "sessionId": .string(binding.sourceNativeSessionID),
        "targetSessionId": .string(binding.targetNativeSessionID),
        "requestId": .string(binding.requestID),
      ]))
    let current = try await store.workbenchProjectBinding(logicalSessionID: logicalID) ?? binding
    if current.phase == .committed || current.phase == .cancelled { return }
    if result["targetCreated"]?.boolValue == true,
      let boundary = result["sourceBoundarySeq"]?.intValue
    {
      try await bindSession(binding.targetNativeSessionID, projectID: binding.projectID)
      _ = try await store.finishStoppedWorkbenchProjectBinding(
        logicalSessionID: logicalID,
        expectedVersion: current.version, boundarySeq: Int64(boundary))
      nativeLogicalIDs[binding.targetNativeSessionID] = logicalID
      try await application.stopEmbeddedDSHExecution(
        sessionID: binding.targetNativeSessionID,
        projectID: ProjectID(rawValue: binding.projectID), releasesRoot: releasesExecution)
    } else {
      _ = try await store.advanceWorkbenchProjectBinding(
        logicalSessionID: logicalID,
        expectedVersion: current.version, phase: .cancelled)
    }
  }
}

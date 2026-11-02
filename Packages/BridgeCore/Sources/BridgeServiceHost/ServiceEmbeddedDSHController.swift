import BridgeACP
import BridgeDomain
import BridgeEmbeddedDSH
import BridgeIPC
import BridgeSecurity
import BridgeServiceApplication
import BridgeServiceCore
import Foundation

public actor ServiceEmbeddedDSHController {
  let application: BridgeServiceApplication
  let projects: ServiceProjectService
  let store: SimpleServiceStore
  let secretStore: any SecretStore
  let dataRoot: URL
  let resourceRoot: URL?
  let externalChildRecovery:
    @Sendable (EmbeddedDSHSubagentBinding) async throws -> EmbeddedDSHReconciledOutcome?
  var runtime: EmbeddedDSHRuntime?
  var sessionProjects: [String: String] = [:]
  let inputGate = AsyncMutex()
  let nativeClientGate = AsyncMutex()
  var nativeClientIndexed = false
  var nativeClientEpoch = 0
  var nativeClientScope: NativeClientScope?
  var nativeClientStreams: [String: NativeClientStream] = [:]
  var eventCursor = 0
  var eventBytes = 0
  var events: [(cursor: Int, value: ACPJSONValue, bytes: Int)] = []
  var isShuttingDown = false
  var recovery: Task<Void, Error>?
  var operationTasks: [String: Task<Void, Never>] = [:]
  var operationGates: [String: AsyncMutex] = [:]
  let operationAdmission = WorkbenchOperationAdmission()
  let runtimeAdmission = WorkbenchOperationAdmission()
  var nativeLogicalIDs: [String: String] = [:]
  var bindingTasks: [String: Task<ACPJSONValue, Error>] = [:]
  var attachmentUploads: [String: WorkbenchAttachmentUpload] = [:]
  var idleApplyTask: Task<Void, Never>?
  var isApplyingConfiguration = false
  var activeMutationRequests = 0

  public init(
    application: BridgeServiceApplication,
    projects: ServiceProjectService,
    store: SimpleServiceStore,
    secretStore: any SecretStore,
    dataRoot: URL,
    resourceRoot: URL? = nil,
    externalChildRecovery:
      @escaping @Sendable (EmbeddedDSHSubagentBinding) async throws -> EmbeddedDSHReconciledOutcome? =
      {
        _ in nil
      }
  ) {
    self.application = application
    self.projects = projects
    self.store = store
    self.secretStore = secretStore
    self.dataRoot = dataRoot
    self.resourceRoot = resourceRoot
    self.externalChildRecovery = externalChildRecovery
  }

  public func call(_ request: IPCEmbeddedDSHRequest) async throws -> IPCEmbeddedDSHResponse {
    guard !isShuttingDown else { throw CancellationError() }
    while isApplyingConfiguration, !["events", "operations.read"].contains(request.action) {
      try await Task.sleep(for: .milliseconds(30))
      guard !isShuttingDown else { throw CancellationError() }
    }
    let mutation = Self.isMutationAction(request.action)
    if mutation { activeMutationRequests += 1 }
    defer { if mutation { activeMutationRequests -= 1 } }
    guard request.payloadJSON.utf8.count <= 2 * 1_024 * 1_024,
      let data = request.payloadJSON.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(ACPJSONValue.self, from: data),
      let payload = decoded.objectValue
    else { throw ServiceStoreError.invalidArgument("embedded_dsh.payload") }
    let result: ACPJSONValue
    if request.action.hasPrefix("operations.") {
      result = try await operationAction(request.action, payload: payload)
    } else if request.action.hasPrefix("attachments.") {
      result = try attachmentAction(request.action, payload: payload)
    } else {
      result = try await performAction(request.action, payload: payload)
    }
    return IPCEmbeddedDSHResponse(resultJSON: try Self.json(result))
  }

  func performAction(
    _ action: String, payload input: [String: ACPJSONValue],
    tracksOperation: Bool = true
  ) async throws -> ACPJSONValue {
    if tracksOperation, Self.durableActions.contains(action) {
      return try await performDurableAction(action, payload: input)
    }
    var payload = input
    if action != "session.create", let id = payload["sessionId"]?.stringValue {
      payload["sessionId"] = .string(try await nativeSessionID(for: id))
    }
    if action == "session.prompt" { return try await performPrompt(payload) }
    if ["schedule.create", "schedule.createStatus", "schedule.catchUp"].contains(action) {
      payload = try await frozenScheduleTarget(action, input: input, resolved: payload)
    }
    let result: ACPJSONValue
    if action == "events" {
      result = try await readEvents(.object(payload))
    } else if action == "runtime.restart" {
      result = try await restartEngine()
    } else if action == "runtime.applyWhenIdle" {
      result = scheduleIdleApply()
    } else if action == "session.bindProject" {
      return try await bindProject(input)
    } else if action == "session.resolve" {
      return try await resolveSession(input)
    } else if action == "session.fileReferences" {
      return try await projectFileReferences(payload)
    } else if action.hasPrefix("client.") {
      result = try await nativeClient(action: action, payload: payload)
    } else if action == "session.create" {
      result = try await createSession(payload)
    } else if action == "session.list" {
      result = try await listSessions(payload)
    } else if action == "session.search" {
      result = try await searchSessions(payload)
    } else if action == "pending.list" {
      result = try await pendingInteractions()
    } else if action == "subagents.history" {
      result = try await subagentHistory(payload)
    } else if action == "subagents.approvals" {
      result = try await subagentApprovals(payload)
    } else if action == "subagents.answer" {
      result = try await answerSubagent(payload)
    } else {
      try Self.validateAction(action)
      if let sessionID = payload["sessionId"]?.stringValue {
        try await authorizeSession(sessionID, requiresProject: false)
        try await synchronizeSessionScope(sessionID)
      }
      if action == "session.updateQueue" { try Self.validateQueueUpdate(payload) }
      if action == "plugins.beginInstall" {
        payload["requestId"] = .string(payload["requestId"]?.stringValue ?? UUID().uuidString)
      }
      if action.hasPrefix("session."), action != "session.list" {
        _ = try Self.requiredString(payload, "sessionId")
        if action == "session.stop" { return try await stopSession(payload) }
      }
      let response: ACPJSONValue
      if action.hasPrefix("plugins.") {
        response = try await performPluginAction(action, payload: payload)
      } else {
        response = try await invoke(action: action, payload: .object(payload))
      }
      if action == "status" {
        var status = response.objectValue ?? [:]
        status["capabilities"] = .object([
          "persistentOperations": .bool(true),
          "chatOnly": .bool(true), "contentPaging": .bool(true), "activationState": .bool(true),
        ])
        return .object(status)
      }
      if action == "session.fork", let sessionID = response["sessionId"]?.stringValue {
        let sourceID = try Self.requiredString(payload, "sessionId")
        let projectID = try await storedProjectID(for: sourceID)
        if let projectID { try await bindSession(sessionID, projectID: projectID) }
        _ = try await store.createWorkbenchConversation(
          logicalSessionID: sessionID,
          nativeSessionID: sessionID, projectID: projectID)
        nativeLogicalIDs[sessionID] = sessionID
      }
      if action == "subagents.list" {
        try await bindNativeChildren(response, rootID: Self.requiredString(payload, "sessionId"))
      }
      if action == "session.cancelProjectSelection", let id = input["sessionId"]?.stringValue {
        try await clearWorkspaceRequest(id)
      }
      result = response
    }
    return result
  }

  public func shutdown() async throws {
    guard !isShuttingDown else { return }
    isShuttingDown = true
    idleApplyTask?.cancel()
    resetNativeClient()
    await runtime?.shutdown()
    if let runtime {
      guard await runtime.confirmedStopped() else {
        throw EmbeddedDSHRuntimeError.processTreeStillRunning
      }
      try await finishPreviousExecutions()
      await application.finishAllUnscopedWorkbenchExecutions()
      await finishAllPluginMaintenance()
      self.runtime = nil
    }
  }

  func invoke(action: String, payload: ACPJSONValue) async throws -> ACPJSONValue {
    let engine = try engine()
    if recovery == nil {
      recovery = Task {
        guard await engine.recoverPreviousHost() else {
          throw EmbeddedDSHRuntimeError.transportClosed
        }
        try await self.recoverExecutions()
        try await self.loadConversationMappings()
        Task { await self.restoreOperations() }
      }
    }
    try await recovery?.value
    let priority = [
      "session.prompt", "session.stop", "session.cancelBinding", "approval.answer",
      "question.answer", "commands.execute", "session.selectModel", "permissions.set",
      "session.scope", "session.bindingSnapshot", "session.receipt", "session.stopStatus",
    ].contains(action)
    await runtimeAdmission.acquire(priority: priority)
    defer { runtimeAdmission.release(priority: priority) }
    try Task.checkCancellation()
    let timeout: Duration? =
      ["plugins.install", "plugins.update"].contains(action) ? .seconds(315_360_000) : nil
    return try await engine.call(action: action, payload: payload, timeout: timeout)
  }

  private func finishPreviousExecutions() async throws {
    let executions = try await application.embeddedDSHExecutions()
    for execution in executions where execution.rootActive {
      try await application.finishEmbeddedDSHExecution(
        sessionID: execution.sessionID, projectID: execution.projectID)
    }
  }

  func restartEngine() async throws -> ACPJSONValue {
    resetNativeClient()
    let engine = try engine()
    let executions = try await application.embeddedDSHExecutions()
    for execution in executions {
      try await application.closeEmbeddedDSHExecutionAdmission(
        sessionID: execution.sessionID, projectID: execution.projectID)
    }
    await engine.shutdown()
    guard await engine.confirmedStopped(), await engine.recoverPreviousHost() else {
      throw EmbeddedDSHRuntimeError.transportClosed
    }
    try await recoverExecutions()
    for execution in executions {
      try await application.stopEmbeddedDSHExecution(
        sessionID: execution.sessionID, projectID: execution.projectID)
    }
    try await engine.restart()
    await application.finishAllUnscopedWorkbenchExecutions()
    await finishAllPluginMaintenance()
    recovery = Task {}
    return try await engine.call(action: "status", payload: .object([:]))
  }

  func engine() throws -> EmbeddedDSHRuntime {
    guard !isShuttingDown else { throw CancellationError() }
    if let runtime { return runtime }
    let runtime = EmbeddedDSHRuntime(
      configuration: EmbeddedDSHRuntimeConfiguration(
        resourceRoot: resourceRoot, dataRoot: dataRoot),
      handler: { [weak self] method, payload in
        guard let self else { throw CancellationError() }
        return try await self.callback(method: method, payload: payload)
      },
      onEvent: { [weak self] event in
        await self?.receive(event)
      }
    )
    self.runtime = runtime
    return runtime
  }

  func callback(method: String, payload: ACPJSONValue) async throws -> ACPJSONValue {
    do {
      switch method {
      case "bridge/secret": return try secret(payload)
      case "bridge/agents": return try await agents(payload)
      case "bridge/agentModels": return try await agentModels(payload)
      case "bridge/subagent": return try await subagent(payload)
      case "bridge/execution": return try await execution(payload)
      default: throw ServiceStoreError.invalidArgument("embedded_dsh.callback")
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let mapped = BridgeServiceRequestController.map(error)
      throw EmbeddedDSHCallbackError(code: -32_000, message: "\(mapped.code): \(mapped.message)")
    }
  }

  private static func validateAction(_ action: String) throws {
    let allowed: Set<String> = [
      "status", "session.prompt", "session.stop", "session.history", "session.selectModel",
      "session.rename", "session.fork",
      "settings.get", "settings.save", "settings.remove", "auth.begin", "auth.addAccount",
      "auth.cancel", "auth.signOut", "auth.refreshModels", "pending.list",
      "auth.switchAccount", "auth.removeAccount", "models.list", "models.discover", "plugins.list",
      "plugins.install", "plugins.enable", "plugins.remove", "plugins.update",
      "approval.answer", "question.answer", "subagents.list", "subagents.control",
      "skills.list", "mcp.list", "mcp.save", "mcp.remove", "mcp.setEnabled",
      "permissions.get", "permissions.set",
      "session.receipt", "session.resumePending", "session.content",
      "session.cancelProjectSelection", "configuration.status",
      "plugins.beginInstall", "plugins.installStatus", "plugins.cancelInstall",
      "plugins.dismissInstall", "session.bindingSnapshot", "schedule.preview",
      "schedule.create", "schedule.createStatus", "schedule.pause", "schedule.resume",
      "schedule.catchUp", "schedule.discardMissed", "session.queue", "session.updateQueue",
      "commands.list",
    ]
    guard allowed.contains(action) else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.action")
    }
  }

  private static func isMutationAction(_ action: String) -> Bool {
    ![
      "status", "events", "models.list", "settings.get", "permissions.get", "session.list",
      "session.history", "session.search", "session.content", "pending.list", "subagents.list",
      "subagents.history", "configuration.status", "plugins.list", "plugins.installStatus",
      "mcp.list", "skills.list", "operations.read", "operations.reconcile", "attachments.read",
      "commands.list", "session.queue", "session.receipt", "session.bindingSnapshot",
      "schedule.preview", "schedule.createStatus",
    ].contains(action)
  }

  static func requiredString(_ payload: [String: ACPJSONValue], _ key: String) throws -> String {
    guard let value = payload[key]?.stringValue, !value.isEmpty,
      value.utf8.count <= 16_384, !value.contains("\0")
    else { throw ServiceStoreError.invalidArgument("embedded_dsh.\(key)") }
    return value
  }

  static func json(_ value: ACPJSONValue) throws -> String {
    String(decoding: try value.encodedData(), as: UTF8.self)
  }

  static func value<T: Encodable>(_ value: T) throws -> ACPJSONValue {
    try JSONDecoder().decode(ACPJSONValue.self, from: JSONEncoder().encode(value))
  }
}

import BridgeACP
import BridgeAgentCore
import BridgeDomain
import BridgeEmbeddedDSH
import BridgeFiles
import BridgeIPC
import BridgeSecurity
import BridgeServiceApplication
import BridgeServiceCore
import BridgeSubagentRounds
import Foundation

public actor ServiceEmbeddedDSHController {
  let application: BridgeServiceApplication
  let projects: ServiceProjectService
  let store: SimpleServiceStore
  let settings: ServiceSettings
  let secretStore: any SecretStore
  let workbenchSearch: WorkbenchSearchService
  let dataRoot: URL
  let resourceRoot: URL?
  let workspaces: AgentWorkspaceStore
  let ipcProjection: WorkbenchIPCProjection
  let externalChildRecovery:
    @Sendable (EmbeddedDSHSubagentBinding) async throws -> EmbeddedDSHReconciledOutcome?
  let externalWorkspaceReadiness:
    @Sendable (String, String, AgentWorkspaceSnapshot, String) async throws ->
      AgentWorkspaceIsolationReadiness
  /// Why a provider can never run in an isolated copy, known without making one. Nil means the
  /// provider needs the copy-based readiness check.
  let externalWorkspaceSupport: @Sendable (String) -> String?
  var liveExecutionRoots: Set<String> = []
  var runtime: EmbeddedDSHRuntime?
  var sharedProviders: (any EmbeddedDSHSharedProviders)?
  package var closeCommunityGateway: (@Sendable () async -> Void)?
  package var workbenchGatewaySnapshot: (@Sendable (ACPJSONValue) async throws -> ACPJSONValue)?
  package var workbenchGatewayEndpoint: (@Sendable () async throws -> ACPJSONValue)?
  var pendingCommunityProviderRefresh = false
  var runtimeStarted = false
  var pendingCommunityRefreshTask: Task<Void, Never>?
  var pendingCommunityRefreshGeneration: UInt64 = 0
  var sessionProjects = NativeSessionMap()
  let inputGate = AsyncMutex()
  let subagentLanes = SubagentLanes()
  /// Drives subagent rounds from the ledger; created on first use and once rounds are open.
  var subagentScheduler: SubagentRoundScheduler?
  /// Test seam that replaces the task submission of a subagent; production leaves it unset.
  var subagentSubmitter: SubagentSubmitter?
  /// Test seam that answers engine calls without a runtime; production leaves it unset.
  var engineCallOverride: (@Sendable (String, ACPJSONValue) async throws -> ACPJSONValue)?
  var stopResendDelays = ServiceEmbeddedDSHController.defaultStopResendDelays
  let workspaceRecoveryGate = AsyncMutex()
  let nativeClientGate = AsyncMutex()
  var nativeClientIndexed = false
  var nativeClientEpoch = 0
  var nativeClientScope: NativeClientScope?
  var nativeClientStreams: [String: NativeClientStream] = [:]
  var eventCursor = 0
  var eventBytes = 0
  let eventSignal = EmbeddedDSHEventSignal()
  var events: [(cursor: Int, value: ACPJSONValue, bytes: Int)] = []
  var isShuttingDown = false
  var recovery: Task<Void, Error>?
  var operationsRestoreTask: Task<Void, Never>?
  var operationTasks: [String: Task<Void, Never>] = [:]
  var operationGates: [String: AsyncMutex] = [:]
  let operationAdmission = WorkbenchOperationAdmission()
  let runtimeAdmission = WorkbenchOperationAdmission()
  let toolWriteLeases = EmbeddedDSHToolWriteLeases()
  var nativeLogicalIDs = NativeSessionMap()
  var conversationWrites: UInt64 = 0
  var loadedConversationMappings: ConversationMappingsLoad?
  var nativeScopeMemo: NativeScopeMemo?
  var bindingTasks: [String: Task<ACPJSONValue, Error>] = [:]
  var attachmentUploads: [String: WorkbenchAttachmentUpload] = [:]
  var idleApplyTask: Task<Void, Never>?
  var workspaceMergeMonitor: Task<Void, Never>?
  var workspaceMergeTasks: [String: Task<Void, Never>] = [:]
  var nativeWriteRecoveryTask: Task<Void, Never>?
  var executionRecoveryTask: Task<Void, Never>?
  var isApplyingConfiguration = false
  var activeMutationRequests = 0
  var activeWorkbenchRequests = 0
  var activeRuntimeInvocations = 0
  var isChangingWorkbenchEnabled = false
  var workbenchAvailabilityGeneration: UInt64 = 0

  package init(
    application: BridgeServiceApplication,
    projects: ServiceProjectService,
    store: SimpleServiceStore,
    settings: ServiceSettings? = nil,
    secretStore: any SecretStore,
    dataRoot: URL,
    resourceRoot: URL? = nil,
    workspaces: AgentWorkspaceStore? = nil,
    ipcProjection: WorkbenchIPCProjection,
    externalWorkspaceReadiness:
      @escaping @Sendable (String, String, AgentWorkspaceSnapshot, String) async throws
      -> AgentWorkspaceIsolationReadiness = { _, _, _, _ in
        AgentWorkspaceIsolationReadiness(ready: false, reason: "该执行器尚未启用进程写入隔离。")
      },
    externalWorkspaceSupport: @escaping @Sendable (String) -> String? = { _ in nil },
    externalChildRecovery:
      @escaping @Sendable (EmbeddedDSHSubagentBinding) async throws -> EmbeddedDSHReconciledOutcome? =
      {
        _ in nil
      }
  ) {
    self.application = application
    self.projects = projects
    self.store = store
    self.settings = settings ?? ServiceSettings(store: store)
    self.secretStore = secretStore
    workbenchSearch = WorkbenchSearchService(secretStore: secretStore)
    self.dataRoot = dataRoot
    self.resourceRoot = resourceRoot
    self.ipcProjection = ipcProjection
    self.workspaces =
      workspaces
      ?? AgentWorkspaceStore(
        directory: dataRoot.appendingPathComponent("AgentWorkspaces", isDirectory: true))
    self.externalChildRecovery = externalChildRecovery
    self.externalWorkspaceReadiness = externalWorkspaceReadiness
    self.externalWorkspaceSupport = externalWorkspaceSupport
  }

  public func call(_ request: IPCEmbeddedDSHRequest) async throws -> IPCEmbeddedDSHResponse {
    guard !isShuttingDown else { throw CancellationError() }
    guard !isChangingWorkbenchEnabled else { throw WorkbenchAvailabilityError.busy }
    let tracksRequest = request.action != "events"
    if tracksRequest { activeWorkbenchRequests += 1 }
    defer { if tracksRequest { activeWorkbenchRequests -= 1 } }
    try await requireWorkbenchEnabled()
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
    } else if request.action.hasPrefix("search.settings.") {
      result = try await workbenchSearchSettings(request.action, input: decoded)
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
    if ["context.get", "context.set"].contains(action), input["sessionId"] != nil {
      _ = try Self.requiredString(input, "sessionId")
    }
    var payload = input
    if action != "session.create", let id = payload["sessionId"]?.stringValue {
      let nativeID = try await nativeSessionID(for: id)
      payload["sessionId"] = .string(nativeID)
    }
    if action.hasPrefix("workspace.recovery.") {
      return try await workspaceRecoveryAction(action, payload: payload)
    }
    if action.hasPrefix("workspace.validation.") {
      let projectID = ProjectID(rawValue: try Self.requiredString(payload, "projectID"))
      _ = try await registeredProject(projectID.rawValue)
      switch action {
      case "workspace.validation.get": return try await workspaceValidationGet(projectID: projectID)
      case "workspace.validation.set":
        return try await workspaceValidationSet(projectID: projectID, input: payload)
      default: throw ServiceStoreError.invalidArgument("workbench.workspace_validation_action")
      }
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
    } else if action == "session.archive" {
      result = try await archiveSession(payload, archived: true)
    } else if action == "session.unarchive" {
      result = try await archiveSession(payload, archived: false)
    } else if action == "session.delete" {
      result = try await deleteSession(payload)
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
    } else if action == "skills.import" {
      return try await importLegacyActionSkills(payload)
    } else {
      try Self.validateAction(action)
      if let sessionID = payload["sessionId"]?.stringValue {
        try await authorizeSession(sessionID, requiresProject: false)
        try await synchronizeSessionScope(sessionID)
        if action == "skills.list" {
          await refreshSkillsIfDiskChanged(for: sessionID)
        }
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
        noteConversationWrite()
        nativeLogicalIDs[sessionID] = sessionID
      }
      if action == "subagents.list" {
        let rootID = try Self.requiredString(payload, "sessionId")
        try await bindNativeChildren(response, rootID: rootID)
        return try await enrichSubagentList(response, rootID: rootID)
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
    resetPendingCommunityProviderRefresh()
    eventSignal.notify()
    idleApplyTask?.cancel()
    workspaceMergeMonitor?.cancel()
    workspaceMergeMonitor = nil
    nativeWriteRecoveryTask?.cancel()
    nativeWriteRecoveryTask = nil
    executionRecoveryTask?.cancel()
    executionRecoveryTask = nil
    operationsRestoreTask?.cancel()
    await subagentScheduler?.shutdown()
    subagentScheduler = nil
    let merges = Array(workspaceMergeTasks.values)
    for task in merges { task.cancel() }
    for task in merges { await task.value }
    workspaceMergeTasks.removeAll()
    resetNativeClient()
    await runtime?.shutdown()
    await toolWriteLeases.closeAll()
    if let runtime {
      guard await runtime.confirmedStopped() else {
        throw EmbeddedDSHRuntimeError.processTreeStillRunning
      }
      try await finishPreviousExecutions()
      await application.finishAllUnscopedWorkbenchExecutions()
      await finishAllPluginMaintenance()
      self.runtime = nil
      await closeCommunityGateway?()
      liveExecutionRoots.removeAll()
    }
  }

  /// `waitsForWriter` is for actions that block until another writer releases the project. They
  /// bypass runtime admission so a long wait cannot take one of its few slots.
  func invoke(action: String, payload: ACPJSONValue, waitsForWriter: Bool = false) async throws
    -> ACPJSONValue
  {
    guard !isChangingWorkbenchEnabled else { throw WorkbenchAvailabilityError.busy }
    activeRuntimeInvocations += 1
    defer { activeRuntimeInvocations -= 1 }
    try await requireWorkbenchEnabled()
    if let engineCallOverride { return try await engineCallOverride(action, payload) }
    let engine = try engine()
    try await startedRecovery(engine: engine).value
    try await requireWorkbenchEnabled()
    let priority = [
      "session.prompt", "session.stop", "session.cancelBinding", "approval.answer",
      "question.answer", "commands.execute", "session.selectModel", "session.setTeamMode",
      "permissions.set",
      "session.scope", "session.bindingSnapshot", "session.receipt", "session.stopStatus",
      "context.get", "context.set", "workspace.release", "workspace.cancel",
      "subagent.lease", "subagent.root", "subagent.deliveries",
    ].contains(action)
    if !waitsForWriter { await runtimeAdmission.acquire(priority: priority) }
    defer { if !waitsForWriter { runtimeAdmission.release(priority: priority) } }
    try Task.checkCancellation()
    try await requireWorkbenchEnabled()
    let timeout: Duration? =
      waitsForWriter || ["plugins.install", "plugins.update"].contains(action)
      ? .seconds(315_360_000) : nil
    return try await engine.call(action: action, payload: payload, timeout: timeout)
  }

  private func finishPreviousExecutions() async throws {
    let executions = try await application.embeddedDSHExecutions()
    for execution in executions where execution.rootActive {
      try await validateWorkspaceWriteRecovery(projectID: execution.projectID)
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
    resetPendingCommunityProviderRefresh()
    operationsRestoreTask?.cancel()
    await subagentScheduler?.adapterStopped()
    await engine.shutdown()
    await toolWriteLeases.closeAll()
    guard await engine.confirmedStopped(), await engine.recoverPreviousHost() else {
      throw EmbeddedDSHRuntimeError.transportClosed
    }
    try await recoverExecutions()
    for execution in executions {
      try await application.stopEmbeddedDSHExecution(
        sessionID: execution.sessionID, projectID: execution.projectID)
    }
    await application.finishAllUnscopedWorkbenchExecutions()
    await finishAllPluginMaintenance()
    recovery = Task {}
    try await engine.restart()
    return try await engine.call(action: "status", payload: .object([:]))
  }

  func engine() throws -> EmbeddedDSHRuntime {
    guard !isShuttingDown else { throw CancellationError() }
    if let runtime { return runtime }
    let runtime = EmbeddedDSHRuntime(
      configuration: EmbeddedDSHRuntimeConfiguration(
        resourceRoot: resourceRoot, dataRoot: dataRoot, sharedProviders: sharedProviders != nil),
      prepareDependencies: { [sharedProviders] in
        if let sharedProviders {
          _ = try await sharedProviders.call("status", payload: .object([:]), timeout: nil)
        }
      },
      handler: { [weak self] method, payload in
        guard let self else { throw CancellationError() }
        return try await self.callback(method: method, payload: payload)
      },
      onStarted: { [weak self] in
        await self?.workbenchEngineStarted()
      },
      onEvent: { [weak self] event in
        await self?.receiveWorkbenchEngineEvent(event)
      }
    )
    liveExecutionRoots.removeAll()
    resetPendingCommunityProviderRefresh()
    self.runtime = runtime
    return runtime
  }

  func callback(method: String, payload: ACPJSONValue) async throws -> ACPJSONValue {
    do {
      switch method {
      case "bridge/provider":
        guard let sharedProviders else { throw EmbeddedDSHRuntimeError.invalidConfiguration }
        let action = payload["action"]?.stringValue
        if action == "provider.snapshot" {
          let snapshot = try await sharedProviders.workbenchCall(payload)
          guard let workbenchGatewaySnapshot else { return snapshot }
          return try await workbenchGatewaySnapshot(snapshot)
        }
        if action == "community.gateway.endpoint" {
          guard let workbenchGatewayEndpoint else {
            throw EmbeddedDSHRuntimeError.invalidConfiguration
          }
          return try await workbenchGatewayEndpoint()
        }
        return try await sharedProviders.workbenchCall(payload)
      case "bridge/secret": return try secret(payload)
      case "bridge/workbenchSearch": return try await workbenchSearchCallback(payload)
      case "bridge/skills": return try await handleSkillCallback(payload)
      case "bridge/agents": return try await agents(payload)
      case "bridge/agentModels": return try await agentModels(payload)
      case "bridge/subagent": return try await subagent(payload)
      case "bridge/execution": return try await execution(payload)
      case "bridge/workspaceWrite": return try await validateNativeWorkspaceWrite(payload)
      default: throw ServiceStoreError.invalidArgument("embedded_dsh.callback")
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let mapped = ipcProjection.mapError(error)
      throw EmbeddedDSHCallbackError(code: -32_000, message: "\(mapped.code): \(mapped.message)")
    }
  }

  private static func validateAction(_ action: String) throws {
    let allowed: Set<String> = [
      "status", "session.prompt", "session.stop", "session.history",
      "session.selectModel", "session.setTeamMode",
      "session.rename", "session.fork", "session.archive", "session.unarchive", "session.delete",
      "auth.status", "settings.get", "settings.save", "settings.remove", "auth.begin",
      "context.get", "context.set",
      "auth.addAccount",
      "auth.cancel", "auth.signOut", "auth.refreshModels", "pending.list",
      "auth.switchAccount", "auth.removeAccount", "models.list", "models.discover", "plugins.list",
      "connections.status", "connections.zcode", "connections.workbuddy",
      "plugins.install", "plugins.enable", "plugins.remove", "plugins.update",
      "approval.answer", "question.answer", "subagents.list", "subagents.agents",
      "subagents.control", "skills.list", "skills.import", "mcp.list", "mcp.save", "mcp.remove",
      "mcp.setEnabled",
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
      "status", "events", "models.list", "auth.status", "settings.get", "permissions.get",
      "context.get", "search.settings.get",
      "session.list",
      "session.history", "session.search", "session.content", "pending.list",
      "subagents.list", "subagents.agents",
      "subagents.history", "configuration.status", "plugins.list", "plugins.installStatus",
      "mcp.list", "skills.list", "operations.read", "operations.reconcile", "attachments.read",
      "commands.list", "session.queue", "session.receipt", "session.bindingSnapshot",
      "schedule.preview", "schedule.createStatus", "client.stream.poll",
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

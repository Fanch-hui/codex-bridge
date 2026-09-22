import BridgeIPC
import Foundation

/// Transport-neutral request controller for the background service. Both the
/// macOS XPC exporter and the Windows named pipe listener dispatch decoded
/// request payloads through this type.
public final class BridgeServiceRequestController: @unchecked Sendable {
  let composition: ServiceComposition
  let admission: XPCRequestAdmission
  let streamSink: (any ServiceStreamSink)?
  let streams = StreamRegistry()
  let conversationStreamGate = AsyncMutex()
  var streamingStopped = false
  var stateChangeForwarder: Task<Void, Never>?

  public init(
    composition: ServiceComposition,
    streamSink: (any ServiceStreamSink)? = nil,
    maximumConcurrentRequests: Int = 8
  ) {
    precondition(maximumConcurrentRequests > 0)
    self.composition = composition
    self.streamSink = streamSink
    self.admission = XPCRequestAdmission(
      maximumConcurrent: maximumConcurrentRequests
    )
  }

  public func stopStreaming() {
    Task { [self] in
      await stopStreamingAsync()
    }
  }

  func stopStreamingAsync() async {
    await conversationStreamGate.acquire()
    defer { conversationStreamGate.release() }
    guard !streamingStopped else { return }
    streamingStopped = true
    stateChangeForwarder?.cancel()
    stateChangeForwarder = nil
    let active = streams.takeAll()
    for (taskID, registration) in active {
      registration.forwarder.cancel()
      await composition.application.serviceUnsubscribeConversation(
        taskID: taskID,
        subscriptionID: registration.subscriptionID
      )
    }
  }

  /// Decodes one encoded request payload and returns the encoded response.
  func dispatch(_ request: Data) async -> Data {
    let decoded: BridgeServiceIPCRequest
    do {
      decoded = try BridgeServiceIPCCodec.decodeRequest(request)
    } catch {
      return Self.fallbackFailure(
        requestID: "invalid",
        code: "invalid_request",
        message: "The XPC request is invalid."
      )
    }
    guard admission.acquire() else {
      return Self.fallbackFailure(
        requestID: decoded.requestID,
        code: "busy",
        message: "The service is busy.",
        retryable: true
      )
    }
    defer { admission.release() }
    return await handle(decoded)
  }

  private func handle(_ request: BridgeServiceIPCRequest) async -> Data {
    do {
      return try await handleOperation(request)
    } catch {
      let mapped = Self.map(error)
      return Self.fallbackFailure(
        requestID: request.requestID,
        code: mapped.code,
        message: mapped.message,
        retryable: mapped.retryable
      )
    }
  }

  func handleOperation(_ request: BridgeServiceIPCRequest) async throws -> Data {
    switch request.operation {
    case .getDirectConfiguration, .updateDirectConfiguration:
      return try await handleDirectConfiguration(request)
    case .status:
      await startStateChanges()
      return try await handleStatus(request)
    case .listProjects:
      return try await handleListProjects(request)
    case .registerProject:
      return try await handleRegisterProject(request)
    case .updateProjectPolicy:
      return try await handleUpdateProjectPolicy(request)
    case .removeProject:
      return try await handleRemoveProject(request)
    case .getProjectCommands:
      return try await handleGetProjectCommands(request)
    case .updateProjectCommands:
      return try await handleUpdateProjectCommands(request)
    case .setProjectCommandMode:
      return try await handleSetProjectCommandMode(request)
    case .setWorkbenchProject:
      return try await handleSetWorkbenchProject(request)
    case .setWorkbenchPermissionMode:
      return try await handleSetWorkbenchPermissionMode(request)
    case .getAgentCatalog:
      return try await handleGetAgentCatalog(request)
    case .connectAgentInstallation:
      return try await handleConnectAgentInstallation(request)
    case .registerAgentInstallation:
      return try await handleRegisterAgentInstallation(request)
    case .reprobeAgentInstallation:
      return try await handleReprobeAgentInstallation(request)
    case .setAgentInstallationEnabled:
      return try await handleSetAgentInstallationEnabled(request)
    case .removeAgentInstallation:
      return try await handleRemoveAgentInstallation(request)
    case .getCustomInstructions:
      return try await handleGetCustomInstructions(request)
    case .setCustomInstructions:
      return try await handleSetCustomInstructions(request)
    case .setCodexExecutablePath:
      return try await handleSetCodexExecutablePath(request)
    case .listModels:
      return try await handleListModels(request)
    case .getModelCatalog:
      return try await handleGetModelCatalog(request)
    case .getModelPreferences:
      return try await handleGetModelPreferences(request)
    case .setModelPreferences:
      return try await handleSetModelPreferences(request)
    case .setSupervisorEnabled:
      return try await handleSetSupervisorEnabled(request)
    case .listThreads:
      return try await handleListThreads(request)
    case .listSkills:
      return try await handleListSkills(request)
    case .readThread:
      return try await handleReadThread(request)
    case .listTasks:
      return try await handleListTasks(request)
    case .getTask:
      return try await handleGetTask(request)
    case .stopTask:
      return try await handleStopTask(request)
    case .steerTask:
      return try await handleSteerTask(request)
    case .interruptTask:
      return try await handleInterruptTask(request)
    case .deleteTask:
      return try await handleDeleteTask(request)
    case .getTaskConversation:
      return try await handleGetTaskConversation(request)
    case .subscribeTaskConversation:
      return try await handleSubscribeTaskConversation(request)
    case .unsubscribeTaskConversation:
      return try await handleUnsubscribeTaskConversation(request)
    case .listApprovals:
      return try await handleListApprovals(request)
    case .resolveApproval:
      return try await handleResolveApproval(request)
    case .listDirectApprovals:
      return try await handleListDirectApprovals(request)
    case .approveDirectApproval:
      return try await handleApproveDirectApproval(request)
    case .denyDirectApproval:
      return try await handleDenyDirectApproval(request)
    case .getDirectApprovalMode:
      return try await handleGetDirectApprovalMode(request)
    case .setDirectApprovalMode:
      return try await handleSetDirectApprovalMode(request)
    case .getTaskStartApprovalMode:
      return try await handleGetTaskStartApprovalMode(request)
    case .setTaskStartApprovalMode:
      return try await handleSetTaskStartApprovalMode(request)
    case .submitAgentTask:
      return try await handleSubmitAgentTask(request)
    case .listAgentModels:
      return try await handleListAgentModels(request)
    case .getAgentModelDefault:
      return try await handleGetAgentModelDefault(request)
    case .setAgentModelDefault:
      return try await handleSetAgentModelDefault(request)
    case .getAgentNativePermissionPolicy:
      return try await handleGetAgentNativePermissionPolicy(request)
    case .updateAgentNativePermissionPolicy:
      return try await handleUpdateAgentNativePermissionPolicy(request)
    case .getAgentPermissionRemediation:
      return try await handleGetAgentPermissionRemediation(request)
    case .applyAgentPermissionRemediation:
      return try await handleApplyAgentPermissionRemediation(request)
    case .listDeepSeekHarnessMCPServers:
      return try await handleListDeepSeekHarnessMCPServers(request)
    case .saveDeepSeekHarnessMCPServer:
      return try await handleSaveDeepSeekHarnessMCPServer(request)
    case .deleteDeepSeekHarnessMCPServer:
      return try await handleDeleteDeepSeekHarnessMCPServer(request)
    case .setExposureMode:
      return try await handleSetExposureMode(request)
    case .listMCPClients:
      return try await handleListMCPClients(request)
    case .setMCPClientEnabled:
      return try await handleSetMCPClientEnabled(request)
    case .setMCPClientExposureMode:
      return try await handleSetMCPClientExposureMode(request)
    case .exportMCPClientConfiguration:
      return try await handleExportMCPClientConfiguration(request)
    case .rotateMCPClientCredential:
      return try await handleRotateMCPClientCredential(request)
    case .rotateLocalMCPEndpoint:
      return try await handleRotateLocalMCPEndpoint(request)
    case .configureTunnel:
      return try await handleConfigureTunnel(request)
    case .connectTunnel:
      return try await handleConnectTunnel(request)
    case .disconnectTunnel:
      return try await handleDisconnectTunnel(request)
    case .clearTunnel:
      return try await handleClearTunnel(request)
    case .prepareAppUpdate:
      return try await handlePrepareAppUpdate(request)
    case .cancelAppUpdate:
      return try await handleCancelAppUpdate(request)
    case .shutdownService:
      #if os(Windows)
        return try handleShutdownService(request)
      #else
        return try BridgeServiceIPCCodec.failure(
          requestID: request.requestID,
          error: .init(
            code: "unsupported_operation",
            message: "Service shutdown is unavailable on this platform."
          )
        )
      #endif
    }
  }

}

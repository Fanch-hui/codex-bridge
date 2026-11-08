import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore
import Foundation
import WebKit

extension BridgeServiceAppModel {
  func startAsync() async {
    guard !started, !stopped else { return }
    started = true
    startAppUpdateCheck()
    let status = await resolveRegistrationStatus(reprobe: true)
    guard !stopped else { return }
    switch status {
    case .enabled:
      await connect(includeCatalog: true)
    case .notRegistered:
      await enableBackgroundService()
    case .requiresApproval:
      connectionState = .requiresApproval
      startPolling()
    case .notFound:
      connectionState = .unavailable
      errorMessage = "App Bundle 中没有找到 Codex Bridge 后台 Service。"
    }
  }

  public func shutdownUI() async {
    guard !stopped else { return }
    stopped = true
    appUpdater.cancel()
    started = false
    pollingTask?.cancel()
    pollingTask = nil
    cancelChatBrowserSleep()
    releaseChatWebView()
    closeConversation()
    await closeClient()
    connectionState = .idle
  }

  @discardableResult
  public func shutdownForApplicationTermination() async -> Bool {
    if !keepServiceRunningAfterAppExit {
      let processIDs: [Int32]
      do {
        processIDs = try await registration.processIDsForShutdown()
      } catch {
        errorMessage = "无法检查后台服务退出状态：\(error.localizedDescription)"
        return false
      }
      await disableBackgroundService()
      guard errorMessage == nil else { return false }
      do {
        try await registration.waitForShutdown(processIDs: processIDs)
      } catch {
        errorMessage = "后台服务尚未结束，请稍后重试。"
        return false
      }
    }
    await shutdownUI()
    return true
  }

  func enableBackgroundService() async {
    guard !stopped else { return }
    errorMessage = nil
    await resolveRegistrationStatus(reprobe: true)
    guard !stopped else { return }
    if registrationStatus == .enabled {
      await connect(includeCatalog: true)
      return
    }

    connectionState = .registering
    do {
      try registration.register()
    } catch {
      await resolveRegistrationStatus(reprobe: true)
      guard registrationStatus == .enabled else {
        connectionState =
          registrationStatus == .requiresApproval
          ? .requiresApproval
          : .unavailable
        errorMessage = Self.message(error)
        return
      }
    }

    await resolveRegistrationStatus(reprobe: true)
    guard registrationStatus == .enabled else {
      connectionState =
        registrationStatus == .requiresApproval
        ? .requiresApproval
        : .unavailable
      startPolling()
      return
    }
    await connect(includeCatalog: true)
  }

  func disableBackgroundService() async {
    errorMessage = nil
    pollingTask?.cancel()
    pollingTask = nil
    closeConversation()
    await closeClient()
    do {
      if await registration.probeStatus() != .notRegistered {
        try await registration.unregister()
      }
      await resolveRegistrationStatus(reprobe: true)
      connectionState = .idle
      serviceStatus = nil
      projects = []
      projectPaths = [:]
      defaultProjectID = nil
      agentProviders = []
      agentInstallations = []
      agentModelOptions = []
      agentModelOptionsByProvider = [:]
      agentModelRefreshingProviders = []
      agentModelHydratingProviders = []
      agentModelRefreshErrorsByProvider = [:]
      agentModelCatalogGenerations = [:]
      agentModelCatalogScopes = [:]
      agentModelCatalogLoadedProviders = []
      agentModelHydrationGenerations = [:]
      agentModelRefreshGenerations = [:]
      agentModelDefaultLoadGenerations = [:]
      agentModelDefaultRevisions = [:]
      for task in agentModelDefaultMutationTasks.values {
        task.cancel()
      }
      agentModelDefaultMutationTasks = [:]
      agentModelDefaults = [:]
      openCodeDefaultModel = nil
      openCodeDefaultPermissionMode = "full"
      openCodeDefaultEffort = nil
      isRefreshingAgentModels = false
      agentModelRefreshError = nil
      isManagingAgents = false
      tasks = []
      closeWorkbenchPanes()
      approvals = []
      taskStartApprovalMode = "require"
      projectWriteConcurrency = nil
      workbenchPermissionMode = "full"
      confirmedWorkbenchPermissionMode = "full"
      resolvingApprovalKeys = []
      resolvedTaskApprovalKeys = []
      resolvedDirectApprovalKeys = []
      mcpClients = []
      geminiCloudStatus = nil
      deepSeekHarnessMCPServers = []
      models = []
      modelPreferences = nil
      customInstructions = nil
      modelCatalogError = nil
      threads = []
      skills = []
      selectedThread = nil
      selectedTaskID = nil
      selectedProjectID = nil
      conversationPresentationCache.removeAll()
    } catch {
      await resolveRegistrationStatus(reprobe: true)
      connectionState = .unavailable
      errorMessage = Self.message(error)
    }
  }

  func refresh(
    silent: Bool,
    includeCatalog: Bool,
    forceCatalogRefresh: Bool = false,
    includeSettings: Bool = false
  ) async {
    guard !stopped else { return }
    if refreshInProgress {
      pendingRefresh = true
      pendingVisibleRefresh = pendingVisibleRefresh || !silent
      pendingCatalogRefresh = pendingCatalogRefresh || includeCatalog
      pendingSettingsRefresh = pendingSettingsRefresh || includeSettings
      pendingForceCatalogRefresh = pendingForceCatalogRefresh || forceCatalogRefresh
      return
    }
    await resolveRegistrationStatus()
    guard !stopped else { return }
    guard registrationStatus == .enabled else {
      connectionState =
        registrationStatus == .requiresApproval
        ? .requiresApproval
        : .unavailable
      return
    }
    guard let client else {
      await connect(
        includeCatalog: includeCatalog,
        forceCatalogRefresh: forceCatalogRefresh
      )
      return
    }

    refreshInProgress = true
    if !silent { isRefreshing = true }
    do {
      let refreshedStatus = try await client.status()
      if serviceStatus != refreshedStatus { serviceStatus = refreshedStatus }
      applyWorkbenchPermissionMode(refreshedStatus.workbenchPermissionMode)
      if connectionState != .connected { connectionState = .connected }
      if !silent { lastRefreshAt = Date() }
      if !silent, errorMessage != nil { errorMessage = nil }
      await refreshCollections(
        client: client,
        includeCatalog: includeCatalog,
        includeProjectResources: !silent,
        forceCatalogRefresh: forceCatalogRefresh,
        includeSettings: includeSettings
      )
    } catch {
      // A saturated service still answers (`busy`). Closing the client here would fail every
      // in-flight request on the connection as "unavailable" although the service is healthy.
      if BridgeServiceErrorMessage.remoteFailure(error)?.code != "busy" {
        await closeClient()
        let status = await resolveRegistrationStatus(reprobe: true)
        let nextState: BridgeServiceConnectionState =
          status == .requiresApproval ? .requiresApproval : .unavailable
        if connectionState != nextState { connectionState = nextState }
        if !silent, status != .requiresApproval { errorMessage = Self.message(error) }
      } else if !silent {
        errorMessage = Self.message(error)
      }
    }
    refreshInProgress = false
    if !silent { isRefreshing = false }
    await runPendingRefreshIfNeeded()
  }

  private func runPendingRefreshIfNeeded() async {
    guard pendingRefresh, !stopped else { return }
    let visible = pendingVisibleRefresh
    let includeCatalog = pendingCatalogRefresh
    let includeSettings = pendingSettingsRefresh
    let forceCatalogRefresh = pendingForceCatalogRefresh
    pendingRefresh = false
    pendingVisibleRefresh = false
    pendingCatalogRefresh = false
    pendingSettingsRefresh = false
    pendingForceCatalogRefresh = false
    await refresh(
      silent: !visible,
      includeCatalog: includeCatalog,
      forceCatalogRefresh: forceCatalogRefresh,
      includeSettings: includeSettings
    )
  }

  func reconcileThreadSelection() {
    guard let selectedThreadID else { return }
    let remainsVisible = threads.contains { $0.threadID == selectedThreadID }
    let belongsToTask = tasks.contains { $0.threadID == selectedThreadID }
    guard !remainsVisible, !belongsToTask else { return }
    self.selectedThreadID = nil
    selectedThread = nil
  }

  func reconcileTaskSelection() {
    guard let selectedTaskID else { return }
    guard tasks.contains(where: { $0.taskID == selectedTaskID }) else {
      if conversation?.taskID == selectedTaskID {
        closeConversation()
      }
      self.selectedTaskID = nil
      return
    }
  }

  func applyApprovalSnapshot(_ value: [IPCApprovalSummary]) {
    let incomingKeys = Set(value.map { WorkbenchApprovalResolutionKey.task($0.approvalID) })
    if resolvedTaskApprovalKeys.count > 512 {
      resolvedTaskApprovalKeys.formIntersection(incomingKeys)
    }
    let hiddenKeys = resolvingApprovalKeys.union(resolvedTaskApprovalKeys)
    let visible = value.filter {
      !hiddenKeys.contains(WorkbenchApprovalResolutionKey.task($0.approvalID))
    }
    if approvals != visible { approvals = visible }
  }

  func applyDirectApprovalSnapshot(_ value: [IPCPendingDirectApproval]) {
    let incomingKeys = Set(value.map { WorkbenchApprovalResolutionKey.direct($0.approvalID) })
    if resolvedDirectApprovalKeys.count > 512 {
      resolvedDirectApprovalKeys.formIntersection(incomingKeys)
    }
    let hiddenKeys = resolvingApprovalKeys.union(resolvedDirectApprovalKeys)
    let visible = value.filter {
      !hiddenKeys.contains(WorkbenchApprovalResolutionKey.direct($0.approvalID))
    }
    if directApprovals != visible { directApprovals = visible }
  }

  func currentClient() throws -> any BridgeServiceClientProtocol {
    guard let client, connectionState == .connected else {
      throw BridgeServiceClientError.unavailable
    }
    return client
  }

  func runMutation(
    _ operation:
      @escaping @MainActor @Sendable (any BridgeServiceClientProtocol) async throws
      -> Void
  ) {
    errorMessage = nil
    Task { [weak self] in
      guard let self else { return }
      do {
        try await operation(try self.currentClient())
      } catch {
        self.errorMessage = Self.message(error)
      }
    }
  }

  func updateExposureState(_ mode: MCPServiceExposureMode) {
    guard let serviceStatus else { return }
    self.serviceStatus = IPCServiceStatusResponse(
      status: serviceStatus.status,
      localMCPURL: serviceStatus.localMCPURL,
      exposureMode: mode,
      tunnel: serviceStatus.tunnel,
      workbenchProjectID: serviceStatus.workbenchProjectID,
      workbenchPermissionMode: serviceStatus.workbenchPermissionMode
    )
  }

  func updateWorkbenchPermissionModeState(_ mode: String) {
    guard let serviceStatus else { return }
    self.serviceStatus = IPCServiceStatusResponse(
      status: serviceStatus.status,
      localMCPURL: serviceStatus.localMCPURL,
      exposureMode: serviceStatus.exposureMode,
      tunnel: serviceStatus.tunnel,
      workbenchProjectID: serviceStatus.workbenchProjectID,
      workbenchPermissionMode: mode
    )
  }

  func applyWorkbenchPermissionMode(_ mode: String?) {
    guard workbenchPermissionModeSyncTask == nil else { return }
    var resolved = "full"
    if let mode, mode == "read-only" || mode == "full" { resolved = mode }
    if workbenchPermissionMode != resolved { workbenchPermissionMode = resolved }
    confirmedWorkbenchPermissionMode = resolved
  }

  static func message(_ error: any Error) -> String {
    BridgeServiceErrorMessage.message(error)
  }

  func closeClient() async {
    cancelDeepSeekDesktopPairing()
    codexModelCatalogRequests.invalidate()
    workbenchSettingsController.invalidate()
    stateChangesTask?.cancel()
    stateChangesTask = nil
    let current = client
    client = nil
    await current?.close()
  }

  func startPolling() {
    guard let pollInterval, pollingTask == nil else { return }
    pollingTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, !self.stopped else { return }
        let delay = self.nextPollingDelay(base: pollInterval)
        do {
          try await Task.sleep(for: delay)
        } catch {
          return
        }
        guard !self.stopped else { return }
        await self.refresh(silent: true, includeCatalog: false)
      }
    }
  }

  func nextPollingDelay(base: Duration) -> Duration {
    let needsLiveUpdates =
      connectionState != .connected || tasks.contains(where: \.isActive) || !approvals.isEmpty
      || !directApprovals.isEmpty
      || !resolvingApprovalKeys.isEmpty
      || (serviceStatus?.tunnel.enabled == true && serviceStatus?.tunnel.lifecycle != "ready")
    return needsLiveUpdates ? base : max(base, idlePollInterval)
  }

}

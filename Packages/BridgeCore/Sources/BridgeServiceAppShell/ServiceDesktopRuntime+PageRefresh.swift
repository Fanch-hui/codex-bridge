import BridgeIPC
import BridgeServiceAppCore
import Foundation

extension BridgeServiceAppModel {
  func refreshMCPClientStatus() async {
    guard !mcpClientStatusRefreshInFlight, !stopped, connectionState == .connected,
      let client
    else { return }
    mcpClientStatusRefreshInFlight = true
    defer { mcpClientStatusRefreshInFlight = false }
    let previous = mcpClients
    if let value = try? await client.mcpClients(), previous == mcpClients {
      mcpClients = value
    }
  }

  func preferencesWindowDidAppear() {
    guard !preferencesWindowIsVisible else { return }
    preferencesWindowIsVisible = true
    Task { [weak self] in await self?.refreshVisiblePreferences() }
  }

  func preferencesWindowDidDisappear() {
    preferencesWindowIsVisible = false
    preferencesWindowIsKey = false
  }

  func refreshVisiblePreferences() async {
    guard preferencesWindowIsVisible, !stopped, connectionState == .connected, client != nil else {
      return
    }
    await refresh(silent: true, includeCatalog: false, includeSettings: true)
  }

  func refreshCurrentPage(_ requestedPage: BridgeServiceNavigation? = nil) async {
    guard !stopped, !isRefreshing else { return }
    let page = requestedPage ?? navigation
    isRefreshing = true
    defer { isRefreshing = false }
    errorMessage = nil
    await resolveRegistrationStatus()
    guard !stopped else { return }
    guard registrationStatus == .enabled else {
      connectionState = registrationStatus == .requiresApproval ? .requiresApproval : .unavailable
      return
    }
    if client == nil {
      await connect(includeCatalog: false, includeCollections: false)
    }
    guard let client else { return }
    do {
      let status = try await client.status()
      if serviceStatus != status { serviceStatus = status }
      applyWorkbenchPermissionMode(status.workbenchPermissionMode)
      if connectionState != .connected { connectionState = .connected }
      await refreshPageCollections(page, client: client)
      lastRefreshAt = Date()
    } catch {
      if BridgeServiceErrorMessage.remoteFailure(error)?.code != "busy" {
        await closeClient()
        let status = await resolveRegistrationStatus(reprobe: true)
        connectionState = status == .requiresApproval ? .requiresApproval : .unavailable
        if status != .requiresApproval { errorMessage = Self.message(error) }
      } else {
        errorMessage = Self.message(error)
      }
    }
  }

  private func refreshPageCollections(
    _ page: BridgeServiceNavigation,
    client: any BridgeServiceClientProtocol
  ) async {
    switch page {
    case .overview:
      await refreshOverviewCollections(client: client)
    case .workbench:
      await refreshWorkbenchCollections(client: client)
    case .projects:
      if let value = try? await client.projectList() { applyProjectSnapshot(value) }
      if let projectID = selectedProjectID,
        let value = try? await client.projectCommands(projectID: projectID)
      {
        if projectDetails[projectID] != value { projectDetails[projectID] = value }
      }
    case .logs:
      if let value = try? await client.tasks(IPCTaskListRequest(limit: 200)) {
        applyTaskSnapshot(value)
      }
    case .connections:
      await refreshConnectionCollections(client: client)
    case .settings:
      await refreshSettingsCollections(client: client)
    }
  }

  private func refreshOverviewCollections(client: any BridgeServiceClientProtocol) async {
    async let projectResult = try? await client.projectList()
    async let agentResult = try? await client.agentCatalog()
    async let taskResult = try? await client.tasks(IPCTaskListRequest(limit: 200))
    async let approvalResult = try? await client.approvals(taskID: nil)
    async let directApprovalResult = try? await client.pendingDirectApprovals()
    async let mcpResult = try? await client.mcpClients()
    async let cloudResult = try? await client.geminiCloudStatus()
    await refreshAgentSetups(client: client)
    if let value = await projectResult { applyProjectSnapshot(value) }
    if let value = await agentResult { applyAgentCatalogSnapshot(value) }
    if let value = await taskResult { applyTaskSnapshot(value) }
    if let value = await approvalResult { applyApprovalSnapshot(value) }
    if let value = await directApprovalResult { applyDirectApprovalSnapshot(value) }
    if let value = await mcpResult, mcpClients != value { mcpClients = value }
    if let value = await cloudResult, geminiCloudStatus != value { geminiCloudStatus = value }
  }

  private func refreshWorkbenchCollections(client: any BridgeServiceClientProtocol) async {
    async let projectResult = try? await client.projectList()
    async let taskResult = try? await client.tasks(IPCTaskListRequest(limit: 200))
    async let approvalResult = try? await client.approvals(taskID: nil)
    async let directApprovalResult = try? await client.pendingDirectApprovals()
    if let value = await projectResult { applyProjectSnapshot(value) }
    if let value = await taskResult { applyTaskSnapshot(value) }
    if let value = await approvalResult { applyApprovalSnapshot(value) }
    if let value = await directApprovalResult { applyDirectApprovalSnapshot(value) }
    if let projectID = selectedProjectID,
      let value = try? await client.skills(projectID: projectID),
      selectedProjectID == projectID
    {
      if skills != value.skills { skills = value.skills }
      lastThreadCatalogRefreshAt = Date()
    }
  }

  private func refreshConnectionCollections(client: any BridgeServiceClientProtocol) async {
    let scope = selectedAgentMCPScope
    async let agentResult = try? await client.agentCatalog()
    await refreshAgentSetups(client: client)
    async let mcpResult = try? await client.mcpClients()
    async let cloudResult = try? await client.geminiCloudStatus()
    async let serverResult = try? await client.deepSeekHarnessMCPServers(scope: scope)
    if let value = await agentResult { applyAgentCatalogSnapshot(value) }
    if let value = await mcpResult, mcpClients != value { mcpClients = value }
    if let value = await cloudResult, geminiCloudStatus != value { geminiCloudStatus = value }
    if let value = await serverResult, selectedAgentMCPScope == scope,
      deepSeekHarnessMCPServers != value.servers
    {
      deepSeekHarnessMCPServers = value.servers
    }
    await refreshConnectionModelSettings(client: client, forceRefresh: true)
  }

  private func refreshSettingsCollections(client: any BridgeServiceClientProtocol) async {
    await workbenchSettingsController.refresh()
    async let configurationResult = try? await client.directConfiguration()
    async let approvalModeResult = try? await client.directApprovalMode()
    async let taskStartModeResult = try? await client.taskStartApprovalMode()
    async let writeConcurrencyResult = try? await client.projectWriteConcurrency()
    async let instructionsResult = try? await client.customInstructions()
    async let mcpClientsResult = try? await client.mcpClients()
    if let value = await configurationResult, directConfiguration != value {
      directConfiguration = value
    }
    if let value = await approvalModeResult, directApprovalMode != value {
      directApprovalMode = value
    }
    if let value = await taskStartModeResult, taskStartApprovalMode != value {
      taskStartApprovalMode = value
    }
    if let value = await writeConcurrencyResult, projectWriteConcurrency != value {
      projectWriteConcurrency = value
    }
    if let value = await instructionsResult, customInstructions != value {
      customInstructions = value
    }
    if let value = await mcpClientsResult, mcpClients != value { mcpClients = value }
  }

  /// Opening the Connections page only fills in what was never loaded. A catalog counts as
  /// loaded once its read finished, even when empty or failed; failures are retried by the page
  /// refresh button or each Agent's own refresh action, never by merely opening the page.
  func loadConnectionSettings() async {
    guard !stopped, connectionState == .connected, let client else { return }
    if let catalog = try? await client.agentCatalog() { applyAgentCatalogSnapshot(catalog) }
    let loads: [Task<Void, Never>?] = agentProviders.map { provider in
      let candidates = agentInstallations.filter {
        $0.providerID == provider.providerID && $0.isEnabled && $0.availability == "available"
      }
      let installation = candidates.first(where: { $0.isActive == true }) ?? candidates.first
      guard agentModelCatalogNeedsInitialLoad(providerID: provider.providerID) else { return nil }
      if let installation {
        return refreshAgentModelCatalog(
          installationID: installation.installationID, providerID: provider.providerID,
          forceRefresh: false)
      }
      return Task {
        await hydrateAgentModelState(installationID: nil, providerID: provider.providerID)
      }
    }
    if models.isEmpty, modelCatalogError == nil, !isRefreshingModels {
      await refreshCodexModels(forceRefresh: false)
    }
    for load in loads { await load?.value }
    await BridgeDesktopCommandRouter.loadNativePermissionPolicyIfNeeded(
      self, forceRefresh: false)?.value
  }

  private func agentModelCatalogNeedsInitialLoad(providerID: String) -> Bool {
    !agentModelCatalogLoadedProviders.contains(providerID)
      && !agentModelRefreshingProviders.contains(providerID)
      && !agentModelHydratingProviders.contains(providerID)
      && agentModelRefreshErrorsByProvider[providerID] == nil
  }

  private func refreshConnectionModelSettings(
    client: any BridgeServiceClientProtocol, forceRefresh: Bool
  ) async {
    if let catalog = try? await client.agentCatalog() { applyAgentCatalogSnapshot(catalog) }
    let refreshes: [Task<Void, Never>?] = agentProviders.map { provider in
      let candidates = agentInstallations.filter {
        $0.providerID == provider.providerID && $0.isEnabled && $0.availability == "available"
      }
      if let installation = candidates.first(where: { $0.isActive == true }) ?? candidates.first {
        return refreshAgentModelCatalog(
          installationID: installation.installationID, providerID: provider.providerID,
          forceRefresh: forceRefresh)
      }
      return Task {
        await hydrateAgentModelState(installationID: nil, providerID: provider.providerID)
      }
    }
    await refreshCodexModels(forceRefresh: forceRefresh)
    for refresh in refreshes { await refresh?.value }
    await BridgeDesktopCommandRouter.loadNativePermissionPolicyIfNeeded(
      self, forceRefresh: forceRefresh)?.value
  }

}

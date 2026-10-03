import BridgeIPC
import BridgeServiceAppCore
import Foundation

extension BridgeServiceAppModel {
  func refreshCurrentPage() async {
    guard !stopped, !isRefreshing else { return }
    let page = navigation
    isRefreshing = true
    defer { isRefreshing = false }
    errorMessage = nil
    registrationStatus = registration.status
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
      connectionState = .connected
      await refreshPageCollections(page, client: client)
      lastRefreshAt = Date()
    } catch {
      await closeClient()
      connectionState = .unavailable
      errorMessage = Self.message(error)
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
      if let value = try? await client.projects() { applyProjectSnapshot(value) }
      if let projectID = selectedProjectID,
        let value = try? await client.projectCommands(projectID: projectID)
      {
        projectDetails[projectID] = value
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
    async let projectResult = try? await client.projects()
    async let agentResult = try? await client.agentCatalog()
    async let taskResult = try? await client.tasks(IPCTaskListRequest(limit: 200))
    async let approvalResult = try? await client.approvals(taskID: nil)
    async let directApprovalResult = try? await client.pendingDirectApprovals()
    if let value = await projectResult { applyProjectSnapshot(value) }
    if let value = await agentResult { applyAgentCatalogSnapshot(value) }
    if let value = await taskResult { applyTaskSnapshot(value) }
    if let value = await approvalResult { applyApprovalSnapshot(value) }
    if let value = await directApprovalResult { applyDirectApprovalSnapshot(value) }
  }

  private func refreshWorkbenchCollections(client: any BridgeServiceClientProtocol) async {
    async let projectResult = try? await client.projects()
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
      skills = value.skills
      lastThreadCatalogRefreshAt = Date()
    }
  }

  private func refreshConnectionCollections(client: any BridgeServiceClientProtocol) async {
    let scope = selectedAgentMCPScope
    async let agentResult = try? await client.agentCatalog()
    async let mcpResult = try? await client.mcpClients()
    async let serverResult = try? await client.deepSeekHarnessMCPServers(scope: scope)
    if let value = await agentResult { applyAgentCatalogSnapshot(value) }
    if let value = await mcpResult { mcpClients = value }
    if let value = await serverResult, selectedAgentMCPScope == scope {
      deepSeekHarnessMCPServers = value.servers
    }
  }

  private func refreshSettingsCollections(client: any BridgeServiceClientProtocol) async {
    let preferenceGeneration = codexModelCatalogRequests.preferenceGeneration
    async let configurationResult = try? await client.directConfiguration()
    async let approvalModeResult = try? await client.directApprovalMode()
    async let taskStartModeResult = try? await client.taskStartApprovalMode()
    async let instructionsResult = try? await client.customInstructions()
    async let preferencesResult = try? await client.modelPreferences()
    if let value = await configurationResult { directConfiguration = value }
    if let value = await approvalModeResult { directApprovalMode = value }
    if let value = await taskStartModeResult { taskStartApprovalMode = value }
    if let value = await instructionsResult { customInstructions = value }
    if let value = await preferencesResult,
      preferenceGeneration == codexModelCatalogRequests.preferenceGeneration,
      !codexModelCatalogRequests.isSavingPreferences
    {
      modelPreferences = value
    }
    if let installationID = focusedAgentNativePermissionInstallationID {
      await loadNativePermissionPolicy(installationID: installationID)
    }
  }
}

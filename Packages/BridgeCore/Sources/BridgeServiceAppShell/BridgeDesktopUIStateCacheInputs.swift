import BridgeDesktopUI
import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore
import Foundation

// Cache keys for `BridgeDesktopUIStateCache`. Each lists every model value its page builder
// reads (directly or through the presentation helpers it calls). Add a field here whenever a
// builder starts reading a new value; an over-inclusive key only costs an extra rebuild.

struct DesktopConnectionsInput: Equatable {
  let serviceStatus: IPCServiceStatusResponse?
  let connectionState: BridgeServiceConnectionState
  let errorMessage: String?
  let modelCount: Int
  let modelCatalogError: String?
  let isRefreshingModels: Bool
  let agentProviders: [IPCAgentProviderSummary]
  let agentInstallations: [IPCAgentInstallationSummary]
  let deepSeekDesktopStates: [String: BridgeDesktopDeepSeekHarnessDesktopState]
  let agentSetupOperations: [IPCAgentSetupState]
  let agentOperationRevision: Int
  let isManagingAgents: Bool
  let deepSeekDesktopBusy: Bool
  let mcpClients: [IPCMCPClientStatus]
  let geminiCloudStatus: IPCGeminiCloudStatus?
  let deepSeekHarnessMCPServers: [IPCDeepSeekHarnessMCPServerSummary]
  let selectedAgentMCPScope: String

  @MainActor
  init(_ model: BridgeServiceAppModel) {
    serviceStatus = model.serviceStatus
    connectionState = model.connectionState
    errorMessage = model.errorMessage
    modelCount = model.models.count
    modelCatalogError = model.modelCatalogError
    isRefreshingModels = model.isRefreshingModels
    agentProviders = model.agentProviders
    agentInstallations = model.agentInstallations
    deepSeekDesktopStates = model.deepSeekDesktopStates
    agentSetupOperations = model.agentSetupOperations
    agentOperationRevision = model.agentOperationRevision
    isManagingAgents = model.isManagingAgents
    deepSeekDesktopBusy = model.deepSeekDesktopBusy
    mcpClients = model.mcpClients
    geminiCloudStatus = model.geminiCloudStatus
    deepSeekHarnessMCPServers = model.deepSeekHarnessMCPServers
    selectedAgentMCPScope = model.selectedAgentMCPScope
  }
}

/// The overview shares the connection page's values and adds the recent sessions, approval
/// count and project names it summarizes.
struct DesktopOverviewInput: Equatable {
  let connections: DesktopConnectionsInput
  let registrationStatus: BridgeServiceRegistrationStatus
  let approvalCount: Int
  let recentTasks: [MCPServiceTaskSnapshot]
  let projects: [MCPProjectSummary]
  let lastRefreshAt: Date?

  @MainActor
  init(_ model: BridgeServiceAppModel, connections: DesktopConnectionsInput) {
    self.connections = connections
    registrationStatus = model.registrationStatus
    approvalCount = model.approvals.count + model.directApprovals.count
    recentTasks = Array(model.tasks.prefix(4))
    projects = model.projects
    lastRefreshAt = model.lastRefreshAt
  }
}

struct DesktopProjectsInput: Equatable {
  let tasksRevision: Int
  let projects: [MCPProjectSummary]
  let projectPaths: [String: String]
  let selectedProjectID: String?
  let selectedProjectDetail: MCPProjectDetail?
  let defaultProjectID: String?
  let selectedTaskID: String?
  let agentProviders: [IPCAgentProviderSummary]
  let agentInstallations: [IPCAgentInstallationSummary]
  let threads: [MCPThreadSummary]
  let selectedThread: MCPThreadReadPage?
  let skills: [MCPServiceSkill]
  let connectionState: BridgeServiceConnectionState

  @MainActor
  init(_ model: BridgeServiceAppModel, tasksRevision: Int) {
    self.tasksRevision = tasksRevision
    projects = model.projects
    projectPaths = model.projectPaths
    selectedProjectID = model.selectedProjectID
    selectedProjectDetail = model.selectedProjectID.flatMap { model.projectDetails[$0] }
    defaultProjectID = model.defaultProjectID
    selectedTaskID = model.selectedTaskID
    agentProviders = model.agentProviders
    agentInstallations = model.agentInstallations
    threads = model.threads
    selectedThread = model.selectedThread
    skills = model.skills
    connectionState = model.connectionState
  }
}

/// Workbench session rows; the rest of the workbench state follows live conversations and
/// is built on every pass.
struct DesktopTaskRowsInput: Equatable {
  let tasksRevision: Int
  let projects: [MCPProjectSummary]
  let selectedTaskID: String?
  let pendingUserInputTaskIDs: Set<String>
  let agentProviders: [IPCAgentProviderSummary]
  let agentInstallations: [IPCAgentInstallationSummary]

  @MainActor
  init(_ model: BridgeServiceAppModel, tasksRevision: Int) {
    self.tasksRevision = tasksRevision
    projects = model.projects
    selectedTaskID = model.selectedTaskID
    pendingUserInputTaskIDs = Set(
      model.approvals.lazy.filter { $0.kind == "user_input" }.map(\.taskID))
    agentProviders = model.agentProviders
    agentInstallations = model.agentInstallations
  }
}

struct DesktopLogsInput: Equatable {
  let tasksRevision: Int
  let projects: [MCPProjectSummary]
  let searchText: String
  let projectID: String?
  let kind: String
  let selectedLogID: String?
  let isRefreshing: Bool

  @MainActor
  init(_ model: BridgeServiceAppModel, tasksRevision: Int) {
    self.tasksRevision = tasksRevision
    projects = model.projects
    searchText = model.desktopLogSearchText
    projectID = model.desktopLogProjectID
    kind = model.desktopLogKind
    selectedLogID = model.desktopSelectedLogID
    isRefreshing = model.isRefreshing
  }
}

struct DesktopSettingsInput: Equatable {
  struct AgentModels: Equatable {
    let defaults: [String: IPCAgentModelDefaultResponse]
    let optionsByProvider: [String: [IPCAgentModelSummary]]
    let openCodeOptions: [IPCAgentModelSummary]
    let openCodeDefaultModel: String?
    let openCodeDefaultPermissionMode: String
    let openCodeDefaultEffort: String?
    let refreshingProviders: Set<String>
    let hydratingProviders: Set<String>
    let refreshErrors: [String: String]

    @MainActor
    init(_ model: BridgeServiceAppModel) {
      defaults = model.agentModelDefaults
      optionsByProvider = model.agentModelOptionsByProvider
      openCodeOptions = model.agentModelOptions
      openCodeDefaultModel = model.openCodeDefaultModel
      openCodeDefaultPermissionMode = model.openCodeDefaultPermissionMode
      openCodeDefaultEffort = model.openCodeDefaultEffort
      refreshingProviders = model.agentModelRefreshingProviders
      hydratingProviders = model.agentModelHydratingProviders
      refreshErrors = model.agentModelRefreshErrorsByProvider
    }
  }

  struct NativePermissions: Equatable {
    let focusedInstallationID: String?
    let policies: [String: IPCAgentNativePermissionPolicyResponse]
    let loadingInstallations: Set<String>
    let savingInstallations: Set<String>
    let errors: [String: String]

    @MainActor
    init(_ model: BridgeServiceAppModel) {
      focusedInstallationID = model.focusedAgentNativePermissionInstallationID
      policies = model.agentNativePermissionPolicies
      loadingInstallations = model.agentNativePermissionLoadingInstallations
      savingInstallations = model.agentNativePermissionSavingInstallations
      errors = model.agentNativePermissionErrors
    }
  }

  let connectionState: BridgeServiceConnectionState
  let registrationStatus: BridgeServiceRegistrationStatus
  let keepServiceRunningAfterAppExit: Bool
  let errorMessage: String?
  let modelPreferences: IPCModelPreferences?
  let models: [MCPModelSummary]
  let isRefreshingModels: Bool
  let modelCatalogError: String?
  let directApprovalMode: String
  let taskStartApprovalMode: String
  let projectWriteConcurrency: Int?
  let customInstructions: String?
  let workbenchSettings: WorkbenchSettingsStatus
  let projects: [MCPProjectSummary]
  let directConfiguration: IPCDirectConfiguration?
  let isSavingDirectConfiguration: Bool
  let directCheck: DirectCommandCheckStatus
  let agentProviders: [IPCAgentProviderSummary]
  let agentInstallations: [IPCAgentInstallationSummary]
  let deepSeekDesktopStates: [String: BridgeDesktopDeepSeekHarnessDesktopState]
  let agentModels: AgentModels
  let nativePermissions: NativePermissions

  @MainActor
  init(_ model: BridgeServiceAppModel) {
    connectionState = model.connectionState
    registrationStatus = model.registrationStatus
    keepServiceRunningAfterAppExit = model.keepServiceRunningAfterAppExit
    errorMessage = model.errorMessage
    modelPreferences = model.modelPreferences
    models = model.models
    isRefreshingModels = model.isRefreshingModels
    modelCatalogError = model.modelCatalogError
    directApprovalMode = model.directApprovalMode
    taskStartApprovalMode = model.taskStartApprovalMode
    projectWriteConcurrency = model.projectWriteConcurrency
    customInstructions = model.customInstructions
    workbenchSettings = model.workbenchSettingsController.state
    projects = model.projects
    directConfiguration = model.directConfiguration
    isSavingDirectConfiguration = model.isSavingDirectConfiguration
    directCheck = model.directCommandChecker.state
    agentProviders = model.agentProviders
    agentInstallations = model.agentInstallations
    deepSeekDesktopStates = model.deepSeekDesktopStates
    agentModels = AgentModels(model)
    nativePermissions = NativePermissions(model)
  }
}

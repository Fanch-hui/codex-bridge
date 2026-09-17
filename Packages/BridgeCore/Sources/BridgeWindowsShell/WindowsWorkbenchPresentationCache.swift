#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore

  struct WindowsWorkbenchPresentationSnapshot {
    let visibleTasks: [MCPServiceTaskSnapshot]
    let visibleSessions: [WorkbenchSessionItem]
    let allSessions: [WorkbenchSessionItem]
    let taskCount: Int
    let runningTaskCount: Int
    let pendingUserInputTaskIDs: Set<String>
    let sessionByTaskID: [String: WorkbenchSessionItem]
    let taskByID: [String: MCPServiceTaskSnapshot]
    let projectByID: [String: MCPProjectSummary]
    let providerByID: [String: IPCAgentProviderSummary]
    let installationByID: [String: IPCAgentInstallationSummary]
    let approvalByID: [String: IPCApprovalSummary]
    let directApprovalByID: [String: IPCPendingDirectApproval]
    let approvalItems: [ApprovalPresentation.Item]

    func projectName(for projectID: String) -> String {
      projectByID[projectID]?.name ?? projectID
    }

    func providerSupportsSteer(for task: MCPServiceTaskSnapshot) -> Bool {
      if task.isCodexTask { return true }
      return providerByID[task.providerIdentifier]?.supportsSteer == true
    }

    func providerSupportsSessionContinuation(for task: MCPServiceTaskSnapshot) -> Bool {
      if task.isCodexTask { return true }
      guard
        providerByID[task.providerIdentifier]?.supportsSessionContinuation == true,
        let installationID = task.installationID,
        let installation = installationByID[installationID]
      else { return false }
      return installation.providerID == task.providerIdentifier
        && installation.isEnabled
        && installation.effectiveCapabilities.contains("lifecycle.session_continue")
    }
  }

  /// Caches the task/session indexes used by the Windows workbench.
  ///
  /// The model marks inputs dirty when it replaces a service snapshot. A
  /// publish caused by a conversation push therefore reuses the session
  /// catalog and all lookup indexes without scanning or sorting tasks again.
  struct WindowsWorkbenchPresentationCache {
    private var tasksDirty = true
    private var projectsDirty = true
    private var providersDirty = true
    private var installationsDirty = true
    private var approvalsDirty = true
    private var visibleProjectID: String?
    private var hasVisibleProject = false

    private var visibleTasks: [MCPServiceTaskSnapshot] = []
    private var visibleSessions: [WorkbenchSessionItem] = []
    private var allSessions: [WorkbenchSessionItem] = []
    private var taskCount = 0
    private var runningTaskCount = 0
    private var pendingUserInputTaskIDs: Set<String> = []
    private var sessionByTaskID: [String: WorkbenchSessionItem] = [:]
    private var taskByID: [String: MCPServiceTaskSnapshot] = [:]
    private var projectByID: [String: MCPProjectSummary] = [:]
    private var providerByID: [String: IPCAgentProviderSummary] = [:]
    private var installationByID: [String: IPCAgentInstallationSummary] = [:]
    private var approvalByID: [String: IPCApprovalSummary] = [:]
    private var directApprovalByID: [String: IPCPendingDirectApproval] = [:]
    private var approvalItems: [ApprovalPresentation.Item] = []

    mutating func approvalsDidChange() { approvalsDirty = true }

    mutating func tasksDidChange() {
      tasksDirty = true
      approvalsDirty = true
    }

    mutating func projectsDidChange() {
      projectsDirty = true
      approvalsDirty = true
    }

    mutating func providersDidChange() {
      providersDirty = true
    }

    mutating func installationsDidChange() {
      installationsDirty = true
    }

    mutating func selectedProjectDidChange() {
      hasVisibleProject = false
    }

    mutating func snapshot(
      tasks: [MCPServiceTaskSnapshot],
      projects: [MCPProjectSummary],
      providers: [IPCAgentProviderSummary],
      installations: [IPCAgentInstallationSummary],
      approvals: [IPCApprovalSummary],
      directApprovals: [IPCPendingDirectApproval],
      selectedProjectID: String?
    ) -> WindowsWorkbenchPresentationSnapshot {
      if tasksDirty {
        taskByID = Self.indexTasks(tasks)
        taskCount = tasks.count
        runningTaskCount = tasks.reduce(into: 0) { count, task in
          if task.isRunning { count += 1 }
        }
        allSessions = WorkbenchSessionCatalog.sessions(tasks: tasks)
          .sorted { $0.latestTask.updatedAt > $1.latestTask.updatedAt }
        sessionByTaskID.removeAll(keepingCapacity: true)
        sessionByTaskID.reserveCapacity(tasks.count)
        for session in allSessions {
          for task in session.tasks {
            sessionByTaskID[task.taskID] = session
          }
        }
        tasksDirty = false
        hasVisibleProject = false
      }

      if projectsDirty {
        projectByID = Self.indexProjects(projects)
        projectsDirty = false
      }

      if providersDirty {
        providerByID = Self.indexProviders(providers)
        providersDirty = false
      }

      if installationsDirty {
        installationByID = Self.indexInstallations(installations)
        installationsDirty = false
      }

      if approvalsDirty {
        approvalByID = Self.indexApprovals(approvals)
        directApprovalByID = Self.indexDirectApprovals(directApprovals)
        approvalItems = Self.makeApprovalItems(
          approvals: approvals,
          directApprovals: directApprovals,
          taskByID: taskByID,
          projectByID: projectByID
        )
        pendingUserInputTaskIDs = Set(
          approvals.lazy.filter { $0.kind == "user_input" }.map(\.taskID)
        )
        approvalsDirty = false
      }

      if !hasVisibleProject || visibleProjectID != selectedProjectID {
        visibleProjectID = selectedProjectID
        visibleTasks =
          selectedProjectID.map { projectID in
            tasks.filter { $0.projectID == projectID }
          } ?? tasks
        visibleSessions =
          selectedProjectID.map { projectID in
            allSessions.filter { $0.projectID == projectID }
          } ?? allSessions
        hasVisibleProject = true
      }

      return WindowsWorkbenchPresentationSnapshot(
        visibleTasks: visibleTasks,
        visibleSessions: visibleSessions,
        allSessions: allSessions,
        taskCount: taskCount,
        runningTaskCount: runningTaskCount,
        pendingUserInputTaskIDs: pendingUserInputTaskIDs,
        sessionByTaskID: sessionByTaskID,
        taskByID: taskByID,
        projectByID: projectByID,
        providerByID: providerByID,
        installationByID: installationByID,
        approvalByID: approvalByID,
        directApprovalByID: directApprovalByID,
        approvalItems: approvalItems
      )
    }

    private static func indexTasks(
      _ tasks: [MCPServiceTaskSnapshot]
    ) -> [String: MCPServiceTaskSnapshot] {
      var index: [String: MCPServiceTaskSnapshot] = [:]
      index.reserveCapacity(tasks.count)
      for task in tasks {
        index[task.taskID] = task
      }
      return index
    }

    private static func indexProjects(
      _ projects: [MCPProjectSummary]
    ) -> [String: MCPProjectSummary] {
      var index: [String: MCPProjectSummary] = [:]
      index.reserveCapacity(projects.count)
      for project in projects {
        index[project.projectID] = project
      }
      return index
    }

    private static func indexProviders(
      _ providers: [IPCAgentProviderSummary]
    ) -> [String: IPCAgentProviderSummary] {
      var index: [String: IPCAgentProviderSummary] = [:]
      index.reserveCapacity(providers.count * 2)
      for provider in providers {
        index[provider.providerID] = provider
        index[AgentProviderPresentation.identifier(provider.providerID)] = provider
      }
      return index
    }

    private static func indexInstallations(
      _ installations: [IPCAgentInstallationSummary]
    ) -> [String: IPCAgentInstallationSummary] {
      var index: [String: IPCAgentInstallationSummary] = [:]
      index.reserveCapacity(installations.count)
      for installation in installations {
        index[installation.installationID] = installation
      }
      return index
    }

    private static func indexApprovals(
      _ approvals: [IPCApprovalSummary]
    ) -> [String: IPCApprovalSummary] {
      var index: [String: IPCApprovalSummary] = [:]
      index.reserveCapacity(approvals.count)
      for approval in approvals {
        index[approval.approvalID] = approval
      }
      return index
    }

    private static func indexDirectApprovals(
      _ approvals: [IPCPendingDirectApproval]
    ) -> [String: IPCPendingDirectApproval] {
      var index: [String: IPCPendingDirectApproval] = [:]
      index.reserveCapacity(approvals.count)
      for approval in approvals {
        index[approval.approvalID] = approval
      }
      return index
    }

    private static func makeApprovalItems(
      approvals: [IPCApprovalSummary],
      directApprovals: [IPCPendingDirectApproval],
      taskByID: [String: MCPServiceTaskSnapshot],
      projectByID: [String: MCPProjectSummary]
    ) -> [ApprovalPresentation.Item] {
      let taskItems = approvals.map { approval in
        let projectName = taskByID[approval.taskID].flatMap {
          projectByID[$0.projectID]?.name
        }
        return ApprovalPresentation.task(approval, projectName: projectName)
      }
      let directItems = directApprovals.map { approval in
        ApprovalPresentation.direct(
          approval,
          projectName: projectByID[approval.projectID]?.name
        )
      }
      return taskItems + directItems
    }
  }

#endif

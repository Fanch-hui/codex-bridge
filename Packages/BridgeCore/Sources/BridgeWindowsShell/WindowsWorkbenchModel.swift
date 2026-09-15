#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore
  import Foundation

  /// Value snapshot the Win32 message-loop thread renders. Updated only by the
  /// model on the main actor; consumed through `WorkbenchDisplayBox`.
  public struct WindowsRecentTaskPresentation: Equatable, Sendable {
    public let taskID: String
    public let title: String
    public let projectName: String
    public let source: String
    public let status: String
    public let updatedAt: String

    public init(
      taskID: String,
      title: String,
      projectName: String,
      source: String,
      status: String,
      updatedAt: String
    ) {
      self.taskID = taskID
      self.title = title
      self.projectName = projectName
      self.source = source
      self.status = status
      self.updatedAt = updatedAt
    }
  }

  public struct WindowsWorkbenchDisplay: Equatable, Sendable {
    public enum ConnectionState: Equatable, Sendable {
      case idle
      case connecting
      case connected
      case unavailable
    }

    public var connectionState: ConnectionState
    public var mcpAddress: String
    public var mcpState: String
    public var taskCount: Int
    public var runningTaskCount: Int
    public var pendingApprovalCount: Int
    public var projectRows: [String]
    public var selectedProjectIndex: Int?
    public var selectedProjectID: String? = nil
    public var permissionRows: [String]
    public var selectedPermissionIndex: Int?
    public var permissionMode: String = "workspace-write"
    public var taskRows: [String]
    public var recentTaskRows: [String]
    public var recentTasks: [WindowsRecentTaskPresentation] = []
    public var selectedTaskID: String?
    public var selectedTaskIndex: Int?
    public var taskMetadata: String
    public var conversationText: String
    public var interruptEnabled: Bool
    public var stopEnabled: Bool
    public var deleteEnabled: Bool
    public var steerEnabled: Bool
    public var actionText: String?
    public var approvalRows: [String]
    public var selectedApprovalIndex: Int?
    public var approvalDetailText: String
    public var approvalAllowDecisions: [String]
    public var approvalAllowEnabled: Bool
    public var approvalDenyEnabled: Bool
    public var approvalStatusText: String?
    public var detailText: String?
    public var taskItems: [BridgeDesktopTaskRow] = []
    public var selectedTaskDetail: BridgeDesktopTaskDetail?
    public var history: BridgeDesktopThreadHistoryState = .init()
    public var approvalItems: [BridgeDesktopApprovalRow] = []
    public var browserEnabled: Bool = true
    public var supportsImmediateSteer: Bool = false
    public var canLoadEarlierConversation: Bool = false
    public var defaultModel: String? = nil
    public var availableModelCount: Int = 0
    public var modelError: String? = nil
  }

  /// Lock-guarded bridge between main-actor model updates and the
  /// non-isolated Win32 render loop (single reader, same-thread comparisons).
  public final class WorkbenchDisplayBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = WindowsWorkbenchDisplay(
      connectionState: .idle,
      mcpAddress: "—",
      mcpState: "未知",
      taskCount: 0,
      runningTaskCount: 0,
      pendingApprovalCount: 0,
      projectRows: [],
      selectedProjectIndex: nil,
      permissionRows: ["只读", "可写"],
      selectedPermissionIndex: 1,
      taskRows: [],
      recentTaskRows: [],
      recentTasks: [],
      selectedTaskID: nil,
      selectedTaskIndex: nil,
      taskMetadata: "未选择任务",
      conversationText: "请从上方选择任务。",
      interruptEnabled: false,
      stopEnabled: false,
      deleteEnabled: false,
      steerEnabled: false,
      actionText: nil,
      approvalRows: [],
      selectedApprovalIndex: nil,
      approvalDetailText: "暂无待处理审批。",
      approvalAllowDecisions: [],
      approvalAllowEnabled: false,
      approvalDenyEnabled: false,
      approvalStatusText: nil,
      detailText: nil,
      defaultModel: nil,
      availableModelCount: 0,
      modelError: nil
    )

    public func current() -> WindowsWorkbenchDisplay {
      lock.lock()
      defer { lock.unlock() }
      return value
    }

    func store(_ newValue: WindowsWorkbenchDisplay) {
      lock.lock()
      value = newValue
      lock.unlock()
    }
  }

  /// Windows shell runtime over the cross-platform service client. All
  /// mutations happen on the main actor; the Win32 loop only reads the
  /// display box. (ObservableObject is unavailable on the Windows toolchain,
  /// so the shell subscribes via the box instead of Combine.)
  @MainActor
  public final class WindowsWorkbenchModel {
    public private(set) var connectionState: WindowsWorkbenchDisplay.ConnectionState = .idle
    public private(set) var errorMessage: String?
    public let displayBox = WorkbenchDisplayBox()

    let client: any BridgeServiceClientProtocol
    let feedback: WindowsDesktopFeedbackStore
    var serviceStatus: IPCServiceStatusResponse?
    var projects: [MCPProjectSummary] = []
    var agentProviders: [IPCAgentProviderSummary] = []
    var agentInstallations: [IPCAgentInstallationSummary] = []
    var tasks: [MCPServiceTaskSnapshot] = []
    var threads: [MCPThreadSummary] = []
    var selectedProjectID: String?
    var selectedThreadID: String?
    var selectedThreadPage: MCPThreadReadPage?
    var workbenchPermissionMode = "workspace-write"
    var isChatBrowserEnabled = true
    var selectedTaskID: String?
    var conversation: TaskConversationModel?
    var conversationPresentationCache = TaskConversationPresentationCache()
    var conversationWasTerminal = false
    var actionText: String?
    var approvals: [IPCApprovalSummary] = []
    var directApprovals: [IPCPendingDirectApproval] = []
    var selectedApprovalID: ApprovalPresentation.Identifier?
    var approvalSelectionGeneration: UInt64 = 0
    var resolvingApprovalIDs: Set<ApprovalPresentation.Identifier> = []
    var approvalStatusText: String?
    var approvalRefreshInProgress = false
    var permissionRemediations: [String: IPCAgentPermissionRemediationResponse] = [:]
    var permissionRemediationLoadingTaskIDs: Set<String> = []
    var permissionRemediationApplyingTaskIDs: Set<String> = []
    var permissionRemediationAppliedTaskIDs: Set<String> = []
    var permissionRemediationErrors: [String: String] = [:]
    var models: [MCPModelSummary] = []
    var modelPreferences: IPCModelPreferences?
    var modelError: String?
    var connectionRefreshInProgress = false
    private var taskPollingTask: Task<Void, Never>?

    public convenience init() {
      self.init(feedback: WindowsDesktopFeedbackStore())
    }

    convenience init(feedback: WindowsDesktopFeedbackStore) {
      self.init(
        client: BridgeServiceClient(transport: ServiceTransportFactory.defaultTransport()),
        feedback: feedback
      )
    }

    init(client: any BridgeServiceClientProtocol, feedback: WindowsDesktopFeedbackStore) {
      self.client = client
      self.feedback = feedback
      publishDisplay()
    }

    /// Launches the service if needed, then verifies connectivity via
    /// `status()` and pulls the task list.
    public func startServiceAndConnect() async {
      connectionState = .connecting
      publishDisplay()
      let launched = await Task.detached(priority: .utility) {
        WindowsServiceLauncher.ensureServiceRunning()
      }.value
      guard launched else {
        fail("未能连接后台服务：codex-bridge-service.exe 启动失败或管道未就绪。")
        return
      }
      await connectAndRefresh()
    }

    /// Verifies the pipe transport with a `status()` round trip, then loads tasks.
    public func connectAndRefresh() async {
      guard !connectionRefreshInProgress else { return }
      connectionRefreshInProgress = true
      defer { connectionRefreshInProgress = false }
      connectionState = .connecting
      publishDisplay()
      do {
        let status = try await client.status()
        serviceStatus = status
        projects = (try? await client.projects()) ?? projects
        if let catalog = try? await client.agentCatalog() {
          agentProviders = catalog.providers
          agentInstallations = catalog.installations
        } else {
          agentProviders = []
          agentInstallations = []
        }
        do {
          let catalog = try await client.modelCatalog()
          models = catalog.models
          modelPreferences = catalog.preferences
          modelError = nil
        } catch {
          models = []
          modelPreferences = nil
          modelError = "模型目录读取失败：\(BridgeServiceErrorMessage.message(error))"
        }
        selectedProjectID =
          projects.first(where: { $0.projectID == status.workbenchProjectID })?.projectID
          ?? selectedProjectID
          ?? projects.first?.projectID
        try await synchronizeWorkbenchProject()
        workbenchPermissionMode =
          Self.permissionModes.contains(status.workbenchPermissionMode ?? "")
          ? status.workbenchPermissionMode!
          : workbenchPermissionMode
        errorMessage = nil
        await refreshTasks()
        startTaskPolling()
      } catch {
        fail(BridgeServiceErrorMessage.message(error))
      }
    }

    public func refreshTasks() async {
      await loadTasks()
      guard connectionState == .connected else { return }
      await refreshApprovals()
    }

    public func shutdown() async {
      taskPollingTask?.cancel()
      taskPollingTask = nil
      closeConversation()
      await client.close()
    }

    private func startTaskPolling() {
      guard taskPollingTask == nil else { return }
      taskPollingTask = Task { [weak self] in
        while !Task.isCancelled {
          do {
            try await Task.sleep(for: .seconds(2))
          } catch {
            return
          }
          guard let self, !Task.isCancelled else { return }
          if self.connectionState == .connected {
            await self.refreshTasks()
          } else {
            await self.connectAndRefresh()
          }
        }
      }
    }

    func refreshDisplaySnapshot() {
      publishDisplay()
    }

    private func fail(_ message: String) {
      errorMessage = message
      connectionState = .unavailable
      publishDisplay()
    }

    func loadTasks() async {
      do {
        tasks = try await client.tasks(IPCTaskListRequest())
        errorMessage = nil
        connectionState = .connected
        reconcileSelectedTask()
        selectDefaultTaskIfNeeded()
        publishDisplay()
      } catch {
        fail(BridgeServiceErrorMessage.message(error))
      }
    }

    func reconcileSelectedTask() {
      guard let selectedTaskID else { return }
      guard
        let task = tasks.first(where: {
          $0.taskID == selectedTaskID
            && (selectedProjectID == nil || $0.projectID == selectedProjectID)
        })
      else {
        self.selectedTaskID = nil
        closeConversation()
        conversationWasTerminal = false
        actionText = nil
        return
      }
      if conversation?.taskID != task.taskID || conversationWasTerminal != task.isTerminal {
        openConversation(for: task)
      }
      conversationWasTerminal = task.isTerminal
    }

    func openConversation(for task: MCPServiceTaskSnapshot) {
      closeConversation()
      let sessionTasks = WorkbenchSessionCatalog.sessionTasks(for: task, in: tasks)
      let priorTaskIDs =
        sessionTasks
        .filter { $0.taskID != task.taskID && $0.updatedAt <= task.updatedAt }
        .map(\.taskID)
      let next = TaskConversationModel(
        taskID: task.taskID,
        priorTaskIDs: priorTaskIDs,
        client: client,
        isTerminal: task.isTerminal,
        updateHandler: { [weak self] in
          guard let self, self.conversation?.taskID == task.taskID else { return }
          self.publishDisplay()
        }
      )
      next.restorePresentation(
        conversationPresentationCache.snapshot(for: task.taskID, priorTaskIDs: priorTaskIDs))
      conversation = next
      conversationWasTerminal = task.isTerminal
      Task { [weak self, weak next] in
        await next?.start()
        guard let self, self.conversation === next else { return }
        self.publishDisplay()
      }
    }

    func closeConversation() {
      guard let current = conversation else { return }
      conversationPresentationCache.store(
        current.presentationSnapshot(),
        for: current.taskID
      )
      current.cancel()
      conversation = nil
    }

    var selectedTask: MCPServiceTaskSnapshot? {
      guard let selectedTaskID else { return nil }
      return tasks.first(where: { $0.taskID == selectedTaskID })
    }
  }
#endif

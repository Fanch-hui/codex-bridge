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
    public var projectLoadError: String? = nil
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
    public var commandReceipt: BridgeDesktopWorkbenchCommandReceipt? = nil
  }

  /// Lock-guarded bridge between main-actor model updates and the
  /// non-isolated Win32 render loop (single reader, same-thread comparisons).
  public final class WorkbenchDisplayBox: @unchecked Sendable {
    private let lock = NSLock()
    private var version: UInt64 = 0

    var revision: UInt64 {
      lock.lock()
      defer { lock.unlock() }
      return version
    }
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
      projectLoadError: nil,
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
      defer { lock.unlock() }
      guard self.value != newValue else { return }
      value = newValue
      version &+= 1
    }
  }

  /// Windows shell runtime over the cross-platform service client. All
  /// mutations happen on the main actor; the Win32 loop only reads the
  /// display box. (ObservableObject is unavailable on the Windows toolchain,
  /// so the shell subscribes via the box instead of Combine.)
  @MainActor
  public final class WindowsWorkbenchModel {
    public internal(set) var connectionState: WindowsWorkbenchDisplay.ConnectionState = .idle
    public internal(set) var errorMessage: String?
    var projectLoadError: String?
    public let displayBox = WorkbenchDisplayBox()

    let client: any BridgeServiceClientProtocol
    let feedback: WindowsDesktopFeedbackStore
    var workbenchDisplayCache = WindowsWorkbenchPresentationCache()
    var serviceStatus: IPCServiceStatusResponse?
    var projects: [MCPProjectSummary] = [] {
      didSet { workbenchDisplayCache.projectsDidChange() }
    }
    var agentProviders: [IPCAgentProviderSummary] = [] {
      didSet { workbenchDisplayCache.providersDidChange() }
    }
    var agentInstallations: [IPCAgentInstallationSummary] = [] {
      didSet { workbenchDisplayCache.installationsDidChange() }
    }
    var tasks: [MCPServiceTaskSnapshot] = [] {
      didSet { workbenchDisplayCache.tasksDidChange() }
    }
    var threads: [MCPThreadSummary] = []
    var selectedProjectID: String? {
      didSet { workbenchDisplayCache.selectedProjectDidChange() }
    }
    var selectedThreadID: String?
    var selectedThreadPage: MCPThreadReadPage?
    var workbenchPermissionMode = "workspace-write"
    var isChatBrowserEnabled = true
    var selectedTaskID: String?
    var workbenchCommandReceipt: BridgeDesktopWorkbenchCommandReceipt?
    var conversation: TaskConversationModel?
    var conversationPresentationCache = TaskConversationPresentationCache()
    var windowsConversationPresentationCache = WindowsConversationPresentationCache()
    var conversationWasTerminal = false
    var actionText: String?
    var approvals: [IPCApprovalSummary] = [] {
      didSet { if approvals != oldValue { workbenchDisplayCache.approvalsDidChange() } }
    }
    var directApprovals: [IPCPendingDirectApproval] = [] {
      didSet { if directApprovals != oldValue { workbenchDisplayCache.approvalsDidChange() } }
    }
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
    var onConnected: (@MainActor () async -> Void)?
    var isShuttingDown = false
    var taskPollingTask: Task<Void, Never>?
    var serviceChangesTask: Task<Void, Never>?
    var serviceChangeRefreshTask: Task<Void, Never>?
    var serviceChangeRefreshPending = false
    var deferredCatalogTask: Task<Void, Never>?
    var conversationDisplayTask: Task<Void, Never>?
    var interactionRefreshTask: Task<Void, Never>?
    var taskLoadInProgress = false
    var taskRefreshInProgress = false
    var isWindowVisible = true
    var connectionGeneration: UInt64 = 0

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

  }
#endif

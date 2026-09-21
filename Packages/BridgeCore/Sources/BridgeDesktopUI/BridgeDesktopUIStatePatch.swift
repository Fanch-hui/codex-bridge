import Foundation

/// A revisioned state envelope shared by the macOS and Windows desktop hosts.
///
/// A patch only contains the state domains that changed. The full-state form is
/// used for the first page load, after a reconnect, and whenever the producer
/// cannot prove that the page and host share the same base revision.
public struct BridgeDesktopUIStatePatch: Codable, Equatable, Sendable {
  public static let currentVersion = 1

  public let type: String
  public let baseRevision: UInt64?
  public let nextRevision: UInt64
  public let state: BridgeDesktopUIState?
  public let changes: [Change]

  public init(
    baseRevision: UInt64?,
    nextRevision: UInt64,
    state: BridgeDesktopUIState? = nil,
    changes: [Change] = []
  ) {
    type = "statePatch"
    self.baseRevision = baseRevision
    self.nextRevision = nextRevision
    self.state = state
    self.changes = changes
  }

  public static func full(
    state: BridgeDesktopUIState,
    nextRevision: UInt64
  ) -> Self {
    Self(baseRevision: nil, nextRevision: nextRevision, state: state)
  }

  public var isFull: Bool {
    state != nil
  }

  public struct Change: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
      case conversation
      case taskRows
      case approvals
      case selectedTask
    }

    public enum CollectionMode: String, Codable, Equatable, Sendable {
      case upsert
      case replace
    }

    public let kind: Kind
    public let taskID: String?
    public let conversationMode: CollectionMode?
    public let entries: [BridgeDesktopConversationEntry]?
    public let removedIDs: [String]
    public let conversationState: BridgeDesktopConversationState?
    public let collectionMode: CollectionMode?
    public let taskRows: [BridgeDesktopTaskRow]?
    public let approvalRows: [BridgeDesktopApprovalRow]?
    public let selectedTask: BridgeDesktopTaskDetail?

    private init(
      kind: Kind,
      taskID: String? = nil,
      conversationMode: CollectionMode? = nil,
      entries: [BridgeDesktopConversationEntry]? = nil,
      removedIDs: [String] = [],
      conversationState: BridgeDesktopConversationState? = nil,
      collectionMode: CollectionMode? = nil,
      taskRows: [BridgeDesktopTaskRow]? = nil,
      approvalRows: [BridgeDesktopApprovalRow]? = nil,
      selectedTask: BridgeDesktopTaskDetail? = nil
    ) {
      self.kind = kind
      self.taskID = taskID
      self.conversationMode = conversationMode
      self.entries = entries
      self.removedIDs = removedIDs
      self.conversationState = conversationState
      self.collectionMode = collectionMode
      self.taskRows = taskRows
      self.approvalRows = approvalRows
      self.selectedTask = selectedTask
    }

    public static func conversation(
      taskID: String,
      mode: CollectionMode,
      entries: [BridgeDesktopConversationEntry],
      removedIDs: [String] = [],
      state: BridgeDesktopConversationState?
    ) -> Self {
      Self(
        kind: .conversation,
        taskID: taskID,
        conversationMode: mode,
        entries: entries,
        removedIDs: removedIDs,
        conversationState: state
      )
    }

    public static func taskRows(
      mode: CollectionMode,
      rows: [BridgeDesktopTaskRow],
      removedIDs: [String] = []
    ) -> Self {
      Self(
        kind: .taskRows,
        removedIDs: removedIDs,
        collectionMode: mode,
        taskRows: rows
      )
    }

    public static func approvals(_ rows: [BridgeDesktopApprovalRow]) -> Self {
      Self(kind: .approvals, approvalRows: rows)
    }

    public static func selectedTask(_ task: BridgeDesktopTaskDetail) -> Self {
      Self(kind: .selectedTask, taskID: task.taskID, selectedTask: task)
    }
  }
}

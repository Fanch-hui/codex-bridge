import BridgeMCP
import Foundation

/// Live conversations for the web workbench split view, shared by the macOS and
/// Windows/Linux hosts. Each pane follows the latest task of one session and owns its
/// own conversation model, independent of the host's selected conversation, so a pane
/// keeps streaming while the user types in another one.
@MainActor
public final class WorkbenchPaneConversations {
  public static let maximumPanes = 4

  public private(set) var paneTaskIDs: [String] = []
  private var conversations: [String: TaskConversationModel] = [:]
  private var terminalStates: [String: Bool] = [:]
  private var presentationCache = TaskConversationPresentationCache()
  private var pendingUpdate: Task<Void, Never>?
  private var lastUpdate: ContinuousClock.Instant?
  private let onChange: @MainActor () -> Void

  /// Pane output is coalesced more than the focused conversation: up to four panes stream
  /// at once and every update rebuilds the desktop state.
  private static let minimumSpacing: Duration = .milliseconds(120)

  public init(onChange: @escaping @MainActor () -> Void) {
    self.onChange = onChange
  }

  public func conversation(for taskID: String) -> TaskConversationModel? {
    conversations[taskID]
  }

  /// Validates the requested panes against the task list (deduplicated, at most four)
  /// and returns whether the pane set changed.
  @discardableResult
  public func setPanes(
    _ requested: [String],
    tasks: [MCPServiceTaskSnapshot],
    client: (any BridgeTaskConversationClient)?
  ) -> Bool {
    var seen = Set<String>()
    let known = Set(tasks.map(\.taskID))
    let next = requested.filter { known.contains($0) && seen.insert($0).inserted }
      .prefix(Self.maximumPanes)
    let changed = Array(next) != paneTaskIDs
    paneTaskIDs = Array(next)
    sync(tasks: tasks, client: client)
    return changed
  }

  /// Opens missing conversations, closes dropped ones, and reopens a pane whose task
  /// finished so its final transcript is fetched once.
  public func sync(tasks: [MCPServiceTaskSnapshot], client: (any BridgeTaskConversationClient)?) {
    let byID = Dictionary(tasks.map { ($0.taskID, $0) }, uniquingKeysWith: { first, _ in first })
    paneTaskIDs = paneTaskIDs.filter { byID[$0] != nil }
    for taskID in conversations.keys where !paneTaskIDs.contains(taskID) {
      close(taskID)
    }
    guard let client else { return }
    for taskID in paneTaskIDs {
      guard let task = byID[taskID] else { continue }
      if conversations[taskID] != nil, terminalStates[taskID] == task.isTerminal { continue }
      close(taskID)
      open(task, tasks: tasks, client: client)
    }
  }

  public func removeAll() {
    for taskID in Array(conversations.keys) { close(taskID) }
    paneTaskIDs = []
    presentationCache.removeAll()
    pendingUpdate?.cancel()
    pendingUpdate = nil
  }

  private func open(
    _ task: MCPServiceTaskSnapshot,
    tasks: [MCPServiceTaskSnapshot],
    client: any BridgeTaskConversationClient
  ) {
    let priorTaskIDs = WorkbenchSessionCatalog.sessionTasks(for: task, in: tasks)
      .filter { $0.taskID != task.taskID && $0.updatedAt <= task.updatedAt }
      .map(\.taskID)
    let taskID = task.taskID
    let model = TaskConversationModel(
      taskID: taskID, priorTaskIDs: priorTaskIDs, client: client, isTerminal: task.isTerminal,
      updateHandler: { [weak self] in self?.scheduleUpdate() })
    model.restorePresentation(presentationCache.snapshot(for: taskID, priorTaskIDs: priorTaskIDs))
    conversations[taskID] = model
    terminalStates[taskID] = task.isTerminal
    Task { [weak self, weak model] in
      await model?.start()
      self?.scheduleUpdate()
    }
  }

  private func close(_ taskID: String) {
    guard let model = conversations.removeValue(forKey: taskID) else { return }
    terminalStates[taskID] = nil
    presentationCache.store(model.presentationSnapshot(), for: taskID)
    model.cancel()
  }

  private func scheduleUpdate() {
    guard pendingUpdate == nil else { return }
    let wait = lastUpdate.map { Self.minimumSpacing - $0.duration(to: .now) } ?? .zero
    pendingUpdate = Task { @MainActor [weak self] in
      if wait > .zero { try? await Task.sleep(for: wait) }
      guard !Task.isCancelled, let self else { return }
      self.pendingUpdate = nil
      self.lastUpdate = .now
      self.onChange()
    }
  }
}

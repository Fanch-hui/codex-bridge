import BridgeDomain
import BridgeServiceCore
import Foundation

public struct ConversationChange: Sendable, Equatable {
  public let taskID: TaskID
  public let messageID: Int64?
  public let key: String
  public let role: ServiceTaskMessageRole
  public let kind: ServiceTaskMessageKind
  public let delta: String?
  public let baseContentLength: Int
  public let fullContent: String?
  public let final: Bool
  public let toolName: String?
  public let toolStatus: String?
  public let toolArguments: String?

  public init(
    taskID: TaskID,
    key: String,
    role: ServiceTaskMessageRole,
    kind: ServiceTaskMessageKind,
    delta: String?,
    baseContentLength: Int,
    fullContent: String?,
    final: Bool,
    toolName: String? = nil,
    toolStatus: String? = nil,
    toolArguments: String? = nil,
    messageID: Int64? = nil
  ) {
    self.taskID = taskID
    self.messageID = messageID
    self.key = key
    self.role = role
    self.kind = kind
    self.delta = delta
    self.baseContentLength = baseContentLength
    self.fullContent = fullContent
    self.final = final
    self.toolName = toolName
    self.toolStatus = toolStatus
    self.toolArguments = toolArguments
  }
}

public struct ConversationSubscription: Sendable {
  public let subscriptionID: Int
  public let page: [TaskConversationBuffer.Entry]
  public let updates: AsyncStream<ConversationChange>

  public init(
    subscriptionID: Int,
    page: [TaskConversationBuffer.Entry],
    updates: AsyncStream<ConversationChange>
  ) {
    self.subscriptionID = subscriptionID
    self.page = page
    self.updates = updates
  }
}

public actor TaskConversationBuffer {
  public struct Entry: Sendable, Equatable {
    public let key: String
    public var messageID: Int64?
    public let role: ServiceTaskMessageRole
    public let kind: ServiceTaskMessageKind
    public let content: String
    public let toolName: String?
    public let toolStatus: String?
    public let toolArguments: String?
    public let isFinal: Bool
    public let createdAt: Date
    /// The last provider event represented by this entry. Keeping this on the
    /// buffered entry lets periodic persistence retain activity timing without
    /// rewriting clean messages when the task closes.
    public let updatedAt: Date

    public init(
      key: String,
      role: ServiceTaskMessageRole,
      kind: ServiceTaskMessageKind = .agent,
      content: String,
      toolName: String? = nil,
      toolStatus: String? = nil,
      toolArguments: String? = nil,
      isFinal: Bool,
      createdAt: Date = Date(),
      updatedAt: Date? = nil,
      messageID: Int64? = nil
    ) {
      self.key = key
      self.messageID = messageID
      self.role = role
      self.kind = kind
      self.content = content
      self.toolName = toolName
      self.toolStatus = toolStatus
      self.toolArguments = toolArguments
      self.isFinal = isFinal
      self.createdAt = createdAt
      self.updatedAt = updatedAt ?? createdAt
    }
  }

  public static let maximumRetainedMessagesPerTask = 64
  public static let maximumSubscribersPerTask = 8

  final class TaskState {
    var entries: [Entry] = []
    var index: [String: Int] = [:]
    var dirtyRevisions: [String: Int] = [:]
    var persistedKeys: Set<String> = []
    var nextRevision = 0
    var unflushedCount: Int = 0
    var lastFlush: Date?
    var isFlushing = false
    var flushTask: Task<Void, Never>?
    var cleanupGeneration = 0
    var subscribers: [Int: AsyncStream<ConversationChange>.Continuation] = [:]
    var nextSubscriberID = 0
    var pendingImmediateSteers: [(id: UUID, content: String)] = []
  }

  let tasks: ServiceTaskManager
  private let flushDeltaCount: Int
  private let flushInFlightCount: Int
  private let flushIntervalNanoseconds: UInt64
  private let closeFlushRetryCount: Int
  private let closeFlushRetryDelayNanoseconds: UInt64
  private let failedCloseRetentionNanoseconds: UInt64
  var states: [TaskID: TaskState] = [:]

  public init(
    tasks: ServiceTaskManager,
    flushDeltaCount: Int = 64,
    flushInFlightCount: Int = 64,
    flushIntervalNanoseconds: UInt64 = 1_000_000_000,
    closeFlushRetryCount: Int = 30,
    closeFlushRetryDelayNanoseconds: UInt64 = 100_000_000,
    failedCloseRetentionNanoseconds: UInt64 = 30_000_000_000
  ) {
    self.tasks = tasks
    self.flushDeltaCount = max(1, flushDeltaCount)
    self.flushInFlightCount = max(1, flushInFlightCount)
    self.flushIntervalNanoseconds = max(1, flushIntervalNanoseconds)
    self.closeFlushRetryCount = max(1, closeFlushRetryCount)
    self.closeFlushRetryDelayNanoseconds = max(1, closeFlushRetryDelayNanoseconds)
    self.failedCloseRetentionNanoseconds = max(1, failedCloseRetentionNanoseconds)
  }

  @discardableResult
  public func close(taskID: TaskID) async -> Bool {
    guard let state = states[taskID] else { return true }
    state.flushTask?.cancel()
    state.flushTask = nil
    state.cleanupGeneration &+= 1
    for (index, entry) in state.entries.enumerated() where !entry.isFinal {
      state.entries[index] = Entry(
        key: entry.key,
        role: entry.role,
        kind: entry.kind,
        content: entry.content,
        toolName: entry.toolName,
        toolStatus: entry.toolStatus,
        toolArguments: entry.toolArguments,
        isFinal: true,
        createdAt: entry.createdAt,
        updatedAt: entry.updatedAt
      )
      markDirty(taskID: taskID, key: entry.key, in: state)
      notify(
        ConversationChange(
          taskID: taskID,
          key: entry.key,
          role: entry.role,
          kind: entry.kind,
          delta: nil,
          baseContentLength: 0,
          fullContent: entry.content,
          final: true,
          toolName: entry.toolName,
          toolStatus: entry.toolStatus,
          toolArguments: entry.toolArguments
        ),
        in: state
      )
    }
    var didFlush = false
    for attempt in 0..<closeFlushRetryCount {
      if !state.isFlushing,
        await flush(taskID: taskID),
        state.dirtyRevisions.isEmpty
      {
        didFlush = true
        break
      }
      if attempt + 1 < closeFlushRetryCount {
        try? await Task.sleep(nanoseconds: closeFlushRetryDelayNanoseconds)
      }
    }
    guard didFlush else {
      scheduleFailedCloseCleanup(taskID: taskID, state: state)
      return false
    }
    state.flushTask?.cancel()
    state.flushTask = nil
    states.removeValue(forKey: taskID)
    finishStreams(in: state)
    return true
  }

  public func purge(taskID: TaskID) async {
    guard let state = states.removeValue(forKey: taskID) else { return }
    state.flushTask?.cancel()
    state.flushTask = nil
    finishStreams(in: state)
  }

  public func subscribe(taskID: TaskID) async -> ConversationSubscription {
    let state = state(taskID: taskID)
    var continuation: AsyncStream<ConversationChange>.Continuation!
    let stream = AsyncStream<ConversationChange>(
      bufferingPolicy: .bufferingNewest(64)
    ) { continuation = $0 }
    let subscriptionID: Int
    if state.subscribers.count < Self.maximumSubscribersPerTask {
      subscriptionID = state.nextSubscriberID
      state.subscribers[subscriptionID] = continuation
      state.nextSubscriberID += 1
    } else {
      subscriptionID = -1
      continuation.finish()
    }
    return ConversationSubscription(
      subscriptionID: subscriptionID,
      page: state.entries,
      updates: stream
    )
  }

  public func unsubscribe(taskID: TaskID, subscriptionID: Int) async {
    guard subscriptionID >= 0, let state = states[taskID] else { return }
    state.subscribers.removeValue(forKey: subscriptionID)
  }

  public func inFlightCount(taskID: TaskID) async -> Int {
    guard let state = states[taskID] else { return 0 }
    return state.unflushedCount
  }

  public func entries(taskID: TaskID) async -> [Entry] {
    guard let state = states[taskID] else { return [] }
    return state.entries
  }

  @discardableResult
  public func closeAll() async -> [TaskID] {
    let taskIDs = Array(states.keys)
    var failed: [TaskID] = []
    for taskID in taskIDs {
      if !(await close(taskID: taskID)) {
        failed.append(taskID)
      }
    }
    return failed
  }

  func state(taskID: TaskID) -> TaskState {
    if let state = states[taskID] {
      return state
    }
    let state = TaskState()
    states[taskID] = state
    return state
  }

  private func armFlushLoop(taskID: TaskID, state: TaskState) {
    guard state.flushTask == nil else { return }
    let interval = flushIntervalNanoseconds
    state.flushTask = Task { [weak self] in
      do {
        while !Task.isCancelled {
          try await Task.sleep(nanoseconds: interval)
          guard let self else { return }
          await self.flushIfNeeded(taskID: taskID)
        }
      } catch {
        return
      }
    }
  }

  private func flushIfNeeded(taskID: TaskID) async {
    guard let state = states[taskID], state.unflushedCount > 0 else { return }
    if await shouldFlush(state) {
      _ = await flush(taskID: taskID)
    }
  }

  private func scheduleFailedCloseCleanup(taskID: TaskID, state: TaskState) {
    let retention = failedCloseRetentionNanoseconds
    state.flushTask?.cancel()
    state.flushTask = nil
    state.cleanupGeneration &+= 1
    let generation = state.cleanupGeneration
    state.flushTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: retention)
      guard !Task.isCancelled, let self else { return }
      await self.discardFailedClose(taskID: taskID, generation: generation)
    }
  }

  private func discardFailedClose(taskID: TaskID, generation: Int) {
    guard let state = states[taskID], state.cleanupGeneration == generation else { return }
    states.removeValue(forKey: taskID)
    finishStreams(in: state)
  }

  func notify(_ change: ConversationChange, in state: TaskState) {
    for subscriber in state.subscribers.values {
      switch subscriber.yield(change) {
      case .enqueued, .dropped, .terminated:
        continue
      @unknown default:
        continue
      }
    }
  }

  private func finishStreams(in state: TaskState) {
    for subscriber in state.subscribers.values {
      subscriber.finish()
    }
  }

  func shouldFlush(_ state: TaskState) async -> Bool {
    if state.unflushedCount >= min(flushDeltaCount, flushInFlightCount) { return true }
    if let lastFlush = state.lastFlush {
      let interval = Double(flushIntervalNanoseconds) / 1_000_000_000
      return Date().timeIntervalSince(lastFlush) >= interval
    }
    return false
  }

  func markDirty(taskID: TaskID, key: String, in state: TaskState) {
    if state.lastFlush == nil {
      state.lastFlush = Date()
    }
    armFlushLoop(taskID: taskID, state: state)
    state.nextRevision &+= 1
    state.dirtyRevisions[key] = state.nextRevision
    state.unflushedCount += 1
  }

}

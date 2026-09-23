import BridgeDomain
import Foundation

public actor ServiceTaskManager {
  let store: SimpleServiceStore
  private let makeTaskID: @Sendable () -> TaskID
  private let now: @Sendable () -> Date
  public nonisolated let changes: ServiceStateChangeHub
  // Store awaits reenter this actor; serialize read-modify-write cycles per task.
  private var activeMutationTaskIDs: Set<TaskID> = []
  private var mutationWaiters: [TaskID: [MutationWaiter]] = [:]

  public init(
    store: SimpleServiceStore,
    makeTaskID: @escaping @Sendable () -> TaskID = {
      TaskID(rawValue: "tsk-" + UUID().uuidString.lowercased())
    },
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.store = store
    self.makeTaskID = makeTaskID
    self.now = now
    self.changes = ServiceStateChangeHub()
  }

  public func submit(
    _ request: ServiceTaskRequest,
    taskID requestedTaskID: TaskID? = nil,
    queued: Bool = false,
    handoffID: String? = nil
  ) async throws -> ServiceTaskCreationResult {
    let date = now()
    let state = try ServiceTaskState(status: .awaitingLocalApproval)
    let task = try ServiceTaskRecord(
      id: requestedTaskID ?? makeTaskID(),
      projectID: request.projectID,
      source: request.source,
      sourceClientID: request.sourceClientID,
      clientRequestID: request.clientRequestID,
      prompt: request.prompt,
      requestedThreadID: request.requestedThreadID,
      providerID: request.providerID,
      installationID: request.installationID,
      selectionMode: request.selectionMode,
      executionModel: request.executionModel,
      executionEffort: request.executionEffort,
      supervisorModel: request.supervisorModel,
      supervisorEffort: request.supervisorEffort,
      permissionMode: request.permissionMode,
      networkAllowed: request.networkAllowed,
      accessMode: request.accessMode,
      fastMode: request.fastMode,
      queueIfBusy: request.queueIfBusy,
      isQueued: queued,
      state: state,
      createdAt: date,
      updatedAt: date
    )
    let result = try await store.createTask(
      task,
      event: ServiceTaskEventDraft(
        kind: .taskCreated,
        summary: "The task was accepted.",
        createdAt: date
      ),
      handoffID: handoffID
    )
    changes.publish()
    return result
  }

  @discardableResult
  public func begin(taskID: TaskID) async throws -> ServiceTaskRecord {
    return try await mutate(
      taskID: taskID,
      patch: StatePatch(
        status: .starting,
        supervisorStatus: .starting
      ),
      eventKind: .executionStarting,
      summary: "The task was accepted and provider execution is starting."
    )
  }

  @discardableResult
  public func approveAndBegin(
    taskID: TaskID,
    summary: String = "The local user approved this provider invocation.",
    authorization: ServiceTaskExecutionAuthorization? = nil
  ) async throws -> ServiceTaskRecord {
    if let authorization {
      try await beginMutation(taskID: taskID)
      defer { endMutation(taskID: taskID) }
      try Task.checkCancellation()
      let date = now()
      return try await store.approveTask(
        id: taskID,
        authorization: authorization,
        supervisorStatus: try await supervisorStartStatus(taskID: taskID),
        event: ServiceTaskEventDraft(
          kind: .taskApproved,
          summary: summary,
          createdAt: date
        )
      )
    }
    return try await mutate(
      taskID: taskID,
      patch: StatePatch(
        status: .starting,
        supervisorStatus: .starting
      ),
      eventKind: .taskApproved,
      summary: summary,
      expectedStatus: .awaitingLocalApproval
    )
  }

  @discardableResult
  public func denyStart(taskID: TaskID) async throws -> ServiceTaskRecord {
    try await mutate(
      taskID: taskID,
      patch: StatePatch(
        status: .failed,
        resultSummary: .set("The local user denied this provider invocation."),
        failureCode: .set("local_approval_denied")
      ),
      eventKind: .taskFailed,
      summary: "The local user denied this provider invocation.",
      expectedStatus: .awaitingLocalApproval
    )
  }

  @discardableResult
  public func markExecutionStarted(
    taskID: TaskID,
    threadID: String,
    turnID: String
  ) async throws -> ServiceTaskRecord {
    try await mutate(
      taskID: taskID,
      patch: StatePatch(
        codexThreadID: .set(threadID),
        codexTurnID: .set(turnID),
        status: .running
      ),
      eventKind: .executionStarted,
      summary: "Codex started the task turn."
    )
  }

  @discardableResult
  public func markAgentExecutionStarted(
    taskID: TaskID,
    providerSessionID: String,
    providerRunID: String
  ) async throws -> ServiceTaskRecord {
    try await mutate(
      taskID: taskID,
      patch: StatePatch(
        providerSessionID: .set(providerSessionID),
        providerRunID: .set(providerRunID),
        status: .running
      ),
      eventKind: .executionStarted,
      summary: "The agent provider started the task run."
    )
  }

  @discardableResult
  public func updatePlan(taskID: TaskID, currentStep: String) async throws
    -> ServiceTaskRecord
  {
    try await mutate(
      taskID: taskID,
      patch: StatePatch(currentStep: .set(currentStep)),
      eventKind: .planUpdated,
      summary: "The provider updated the current task step."
    )
  }

  @discardableResult
  public func recordChangedFiles(
    taskID: TaskID,
    relativePaths: [String],
    summary: String = "Codex reported project file changes."
  ) async throws -> ServiceTaskRecord {
    try await mutate(
      taskID: taskID,
      patch: StatePatch(changedFilesToAppend: relativePaths),
      eventKind: .fileChanged,
      summary: summary
    )
  }

  @discardableResult
  public func recordCommandCompletion(
    taskID: TaskID,
    summary: String
  ) async throws -> ServiceTaskRecord {
    try await mutate(
      taskID: taskID,
      patch: StatePatch(),
      eventKind: .commandCompleted,
      summary: summary
    )
  }

  @discardableResult
  public func markWaitingForCodexApproval(taskID: TaskID) async throws
    -> ServiceTaskRecord
  {
    try await mutate(
      taskID: taskID,
      patch: StatePatch(status: .waitingForCodexApproval),
      eventKind: .approvalRequested,
      summary: "The provider is waiting for a local approval decision."
    )
  }

  @discardableResult
  public func resumeAfterCodexApproval(taskID: TaskID, approved: Bool) async throws
    -> ServiceTaskRecord
  {
    try await mutate(
      taskID: taskID,
      patch: StatePatch(status: .running),
      eventKind: .approvalResolved,
      summary: approved
        ? "The local user approved the provider request."
        : "The local user denied the provider request; it may continue with a safer path."
    )
  }

  @discardableResult
  public func complete(
    taskID: TaskID,
    resultSummary: String,
    changedFiles: [String],
    eventSummary: String? = nil
  ) async throws -> ServiceTaskRecord {
    try await mutate(
      taskID: taskID,
      patch: StatePatch(
        status: .completed,
        changedFiles: changedFiles,
        resultSummary: .set(resultSummary),
        failureCode: .set(nil)
      ),
      eventKind: .taskCompleted,
      summary: eventSummary ?? "The provider completed the task."
    )
  }

  @discardableResult
  public func fail(
    taskID: TaskID,
    failureCode: String,
    summary: String
  ) async throws -> ServiceTaskRecord {
    return try await mutate(
      taskID: taskID,
      patch: StatePatch(
        status: .failed,
        supervisorStatus: .failed,
        resultSummary: .set(summary),
        failureCode: .set(failureCode)
      ),
      eventKind: .taskFailed,
      summary: summary
    )
  }

  @discardableResult
  public func interrupt(taskID: TaskID, summary: String) async throws -> ServiceTaskRecord {
    try await mutate(
      taskID: taskID,
      patch: StatePatch(status: .interrupted),
      eventKind: .taskInterrupted,
      summary: summary
    )
  }

  @discardableResult
  public func updateSupervisor(
    taskID: TaskID,
    status: ServiceSupervisorStatus,
    summary: String?
  ) async throws -> ServiceTaskRecord {
    let eventKind: ServiceTaskEventKind
    switch status {
    case .starting, .running:
      eventKind = .supervisorStarted
    case .degraded:
      eventKind = .supervisorDegraded
    case .completed, .disabled:
      eventKind = .supervisorDecision
    }
    return try await mutate(
      taskID: taskID,
      patch: StatePatch(
        supervisorStatus: .set(status),
        supervisorSummary: .set(summary)
      ),
      eventKind: eventKind,
      summary: summary ?? "The Supervisor state changed to \(status.rawValue)."
    )
  }

  @discardableResult
  public func recoverIncompleteTasks() async throws -> [ServiceTaskRecord] {
    try await store.markIncompleteTasksUnknown(at: now())
  }

  public func task(id: TaskID) async throws -> ServiceTaskRecord? {
    try await store.task(id: id)
  }

  public func task(
    providerSessionID: String,
    providerID: String,
    installationID: String,
    projectID: ProjectID
  ) async throws -> ServiceTaskRecord? {
    try await store.task(
      providerSessionID: providerSessionID,
      providerID: providerID,
      installationID: installationID,
      projectID: projectID
    )
  }

  public func tasks(projectID: ProjectID? = nil, limit: Int = 100) async throws
    -> [ServiceTaskRecord]
  {
    try await store.tasks(projectID: projectID, limit: limit)
  }

  public func nonterminalTasks() async throws -> [ServiceTaskRecord] {
    try await store.nonterminalTasks()
  }

  public func listActivity(taskIDs: [TaskID]) async throws -> ServiceTaskListActivity {
    try await store.taskListActivity(taskIDs: taskIDs)
  }

  public func events(taskID: TaskID, limit: Int = 100) async throws
    -> [ServiceTaskEventRecord]
  {
    try await store.events(taskID: taskID, limit: limit)
  }

  public func upsertTaskMessage(
    taskID: TaskID,
    key: String,
    role: ServiceTaskMessageRole,
    content: String,
    kind: ServiceTaskMessageKind = .agent,
    toolName: String? = nil,
    toolStatus: String? = nil,
    toolArguments: String? = nil,
    createdAt: Date? = nil,
    updatedAt: Date? = nil
  ) async throws {
    let creationDate = createdAt ?? now()
    let updateDate = updatedAt ?? creationDate
    try await store.upsertTaskMessage(
      ServiceTaskMessageDraft(
        key: key,
        role: role,
        content: content,
        createdAt: creationDate,
        kind: kind,
        toolName: toolName,
        toolStatus: toolStatus,
        toolArguments: toolArguments,
        updatedAt: updateDate
      ),
      taskID: taskID
    )
  }

  public func messages(
    taskID: TaskID,
    beforeMessageID: Int64? = nil,
    limit: Int = 200
  ) async throws -> [ServiceTaskMessageRecord] {
    try await store.taskMessages(
      taskID: taskID,
      beforeMessageID: beforeMessageID,
      limit: limit
    )
  }

  public func message(
    taskID: TaskID,
    key: String
  ) async throws -> ServiceTaskMessageRecord? {
    try await store.taskMessage(taskID: taskID, key: key)
  }

  public func recentMessageActivity(
    taskID: TaskID,
    limit: Int = 12
  ) async throws -> [ServiceTaskMessageRecord] {
    try await store.recentTaskMessageActivity(taskID: taskID, limit: limit)
  }

  public func remove(taskID: TaskID) async throws {
    guard let task = try await store.task(id: taskID) else {
      throw ServiceStoreError.unknownTask(taskID)
    }
    guard task.state.status.isTerminal || task.state.status == .unknown else {
      throw ServiceStoreError.invalidArgument("task.removeActive")
    }
    try await store.removeTask(id: taskID)
  }

  public func activeWriteTask(projectID: ProjectID) async throws -> ServiceTaskRecord? {
    try await store.activeWriteTask(projectID: projectID)
  }

  public func queuedTasks(projectID: ProjectID? = nil, limit: Int = 500) async throws
    -> [ServiceTaskRecord]
  {
    try await store.queuedTasks(projectID: projectID, limit: limit)
  }

  public func queueInfo(taskID: TaskID) async throws -> ServiceTaskQueueInfo? {
    try await store.taskQueueInfo(id: taskID)
  }

  @discardableResult
  public func promoteQueued(taskID: TaskID) async throws -> ServiceTaskRecord? {
    let date = now()
    let promoted = try await store.promoteQueuedTask(
      id: taskID,
      at: date,
      event: ServiceTaskEventDraft(
        kind: .executionStarting,
        summary: "The queued task was admitted after the project became available.",
        createdAt: date
      )
    )
    if promoted != nil { changes.publish() }
    return promoted
  }

  private func mutate(
    taskID: TaskID,
    patch: StatePatch,
    eventKind: ServiceTaskEventKind,
    summary: String,
    expectedStatus: ServiceTaskStatus? = nil
  ) async throws -> ServiceTaskRecord {
    try await beginMutation(taskID: taskID)
    defer { endMutation(taskID: taskID) }
    try Task.checkCancellation()
    let current = try await requiredTask(id: taskID)
    let date = now()
    let state = try Self.apply(patch, to: current)
    let updated = try current.replacingState(state, updatedAt: date)
    try await store.updateTask(
      updated,
      event: ServiceTaskEventDraft(
        kind: eventKind,
        summary: summary,
        createdAt: date
      ),
      expectedStatus: expectedStatus
    )
    return updated
  }

  private func beginMutation(taskID: TaskID) async throws {
    guard activeMutationTaskIDs.contains(taskID) else {
      activeMutationTaskIDs.insert(taskID)
      return
    }
    let waiterID = UUID()
    try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, Error>) in
          guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
          }
          mutationWaiters[taskID, default: []].append(
            MutationWaiter(id: waiterID, continuation: continuation)
          )
        }
      },
      onCancel: { [weak self] in
        Task { await self?.cancelMutationWaiter(taskID: taskID, id: waiterID) }
      })
  }

  private func cancelMutationWaiter(taskID: TaskID, id: UUID) {
    guard var waiters = mutationWaiters[taskID],
      let index = waiters.firstIndex(where: { $0.id == id })
    else { return }
    let waiter = waiters.remove(at: index)
    mutationWaiters[taskID] = waiters.isEmpty ? nil : waiters
    waiter.continuation.resume(throwing: CancellationError())
  }

  private func endMutation(taskID: TaskID) {
    guard var waiters = mutationWaiters[taskID], !waiters.isEmpty else {
      activeMutationTaskIDs.remove(taskID)
      changes.publish()
      return
    }
    let next = waiters.removeFirst()
    mutationWaiters[taskID] = waiters.isEmpty ? nil : waiters
    next.continuation.resume()
    changes.publish()
  }

  private func requiredTask(id: TaskID) async throws -> ServiceTaskRecord {
    guard let task = try await store.task(id: id) else {
      throw ServiceStoreError.unknownTask(id)
    }
    return task
  }

  private func supervisorStartStatus(taskID: TaskID) async throws -> ServiceSupervisorStatus {
    let task = try await requiredTask(id: taskID)
    return task.supervisorModel == nil ? .disabled : .starting
  }

  private static func apply(
    _ patch: StatePatch,
    to task: ServiceTaskRecord
  ) throws -> ServiceTaskState {
    let current = task.state
    return try ServiceTaskState(
      codexThreadID: patch.codexThreadID.applying(to: current.codexThreadID),
      codexTurnID: patch.codexTurnID.applying(to: current.codexTurnID),
      providerSessionID: patch.providerSessionID.applying(to: current.providerSessionID),
      providerRunID: patch.providerRunID.applying(to: current.providerRunID),
      status: patch.status ?? current.status,
      supervisorStatus: patch.supervisorStatus.applying(to: task),
      currentStep: patch.currentStep.applying(to: current.currentStep),
      changedFiles: patch.changedFiles
        ?? Array(Set(current.changedFiles + patch.changedFilesToAppend)).sorted(),
      resultSummary: patch.resultSummary.applying(to: current.resultSummary),
      supervisorSummary: patch.supervisorSummary.applying(to: current.supervisorSummary),
      failureCode: patch.failureCode.applying(to: current.failureCode)
    )
  }

  private struct MutationWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, Error>
  }
}

private struct StatePatch: Sendable {
  var codexThreadID: OptionalUpdate<String> = .keep
  var codexTurnID: OptionalUpdate<String> = .keep
  var providerSessionID: OptionalUpdate<String> = .keep
  var providerRunID: OptionalUpdate<String> = .keep
  var status: ServiceTaskStatus?
  var supervisorStatus: SupervisorUpdate = .keep
  var currentStep: OptionalUpdate<String> = .keep
  var changedFiles: [String]?
  var changedFilesToAppend: [String] = []
  var resultSummary: OptionalUpdate<String> = .keep
  var supervisorSummary: OptionalUpdate<String> = .keep
  var failureCode: OptionalUpdate<String> = .keep
}

private enum OptionalUpdate<Value: Sendable>: Sendable {
  case keep
  case set(Value?)

  func applying(to current: Value?) -> Value? {
    switch self {
    case .keep:
      current
    case .set(let value):
      value
    }
  }
}

private enum SupervisorUpdate: Sendable {
  case keep
  case set(ServiceSupervisorStatus)
  case starting
  case failed

  func applying(to task: ServiceTaskRecord) -> ServiceSupervisorStatus {
    switch self {
    case .keep:
      task.state.supervisorStatus
    case .set(let status):
      status
    case .starting:
      task.supervisorModel == nil ? .disabled : .starting
    case .failed:
      task.state.supervisorStatus == .disabled ? .disabled : .degraded
    }
  }
}

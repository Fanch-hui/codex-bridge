/// Produces a small patch when the new state differs only in a patchable
/// domain: the workbench collections, the selected task's conversation, or
/// the volatile page domains (overview, connections, logs, appUpdate). It
/// deliberately falls back to a full snapshot for any ambiguous change so
/// the page never applies a partial state over the wrong base revision.
public struct BridgeDesktopUIStatePatchBuilder: Sendable {
  private var previousState: BridgeDesktopUIState?
  private var previousRevision: UInt64?

  public init() {}

  public mutating func makePatch(
    state: BridgeDesktopUIState,
    nextRevision: UInt64
  ) -> BridgeDesktopUIStatePatch {
    defer {
      previousState = state
      previousRevision = nextRevision
    }

    guard let previousState, let previousRevision,
      previousRevision &+ 1 == nextRevision
    else {
      return .full(state: state, nextRevision: nextRevision)
    }

    guard let changes = patchChanges(from: previousState, to: state) else {
      // The change cannot be expressed as a patch (selection, workbench
      // shell, unknown domain); only a full snapshot can carry it.
      return .full(state: state, nextRevision: nextRevision)
    }
    // An empty change set is a provable no-op (for example a poll tick that
    // only refreshed timestamps); keep the revision chain advancing with an
    // empty patch instead of re-shipping the full state.
    return BridgeDesktopUIStatePatch(
      baseRevision: previousRevision,
      nextRevision: nextRevision,
      changes: changes
    )
  }

  public func fullSnapshot(
    state: BridgeDesktopUIState,
    revision: UInt64
  ) -> BridgeDesktopUIStatePatch {
    .full(state: state, nextRevision: revision)
  }

  private func patchChanges(
    from old: BridgeDesktopUIState,
    to new: BridgeDesktopUIState
  ) -> [BridgeDesktopUIStatePatch.Change]? {
    // Identical states are the canonical provable no-op, whatever their shape.
    // Without this, a state without a workbench (any non-workbench page)
    // would re-ship in full on every poll tick that changed nothing.
    guard old != new else { return [] }
    guard sameGlobalState(old, new), let oldWorkbench = old.workbench,
      let newWorkbench = new.workbench,
      sameWorkbenchShell(oldWorkbench, newWorkbench)
    else {
      return nil
    }

    var changes: [BridgeDesktopUIStatePatch.Change] = []
    if old.overview != new.overview {
      changes.append(.overview(new.overview))
    }
    if old.connections != new.connections {
      changes.append(.connection(new.connections))
    }
    if old.logs != new.logs {
      changes.append(.logs(new.logs))
    }
    if old.appUpdate != new.appUpdate {
      changes.append(.appUpdate(new.appUpdate))
    }
    if oldWorkbench.browser != newWorkbench.browser {
      changes.append(.browser(newWorkbench.browser))
    }
    if oldWorkbench.tasks != newWorkbench.tasks {
      let (mode, rows, removedIDs) = rowsPatch(
        old: oldWorkbench.tasks,
        new: newWorkbench.tasks,
        id: \.taskID
      )
      changes.append(.taskRows(mode: mode, rows: rows, removedIDs: removedIDs))
    }
    if oldWorkbench.approvals != newWorkbench.approvals {
      changes.append(.approvals(newWorkbench.approvals))
    }

    guard oldWorkbench.selectedTaskID == newWorkbench.selectedTaskID else {
      return nil
    }
    switch (oldWorkbench.selectedTask, newWorkbench.selectedTask) {
    case (let oldTask?, let newTask?) where taskMetadataEqual(oldTask, newTask):
      if let conversation = conversationPatch(from: oldTask, to: newTask) {
        changes.append(conversation)
      }
    case (_, let newTask?):
      changes.append(.selectedTask(newTask))
    case (nil, nil):
      break
    default:
      return nil
    }
    return changes
  }

  /// Everything a patch cannot express must be identical for the patch path.
  /// The volatile page domains (overview, connections, logs, appUpdate) are
  /// excluded here: they churn on every poll tick or log line and are carried
  /// by their own change kinds instead of forcing a full snapshot.
  private func sameGlobalState(
    _ old: BridgeDesktopUIState,
    _ new: BridgeDesktopUIState
  ) -> Bool {
    old.hostContext == new.hostContext
      && old.navigation == new.navigation
      && old.selectedNavigation == new.selectedNavigation
      && old.connectionLabel == new.connectionLabel
      && old.connectionTone == new.connectionTone
      && old.isRefreshing == new.isRefreshing
      && old.feedback == new.feedback
      && old.projects == new.projects
      && old.settings == new.settings
  }

  private func sameWorkbenchShell(
    _ old: BridgeDesktopWorkbenchState,
    _ new: BridgeDesktopWorkbenchState
  ) -> Bool {
    old.header == new.header
      && old.projects == new.projects
      && old.selectedProjectID == new.selectedProjectID
      && old.permissionMode == new.permissionMode
      && old.permissionOptions == new.permissionOptions
      && old.selectedTaskID == new.selectedTaskID
      && old.history == new.history
      && old.taskHistorySearch == new.taskHistorySearch
      && old.nativeSessions == new.nativeSessions
      && old.steerModes == new.steerModes
      && old.projectStatus == new.projectStatus
      && old.projectStatusTone == new.projectStatusTone
      && old.engineStatus == new.engineStatus
      && old.modelCount == new.modelCount
      && old.canRefreshModels == new.canRefreshModels
      && old.isRefreshingModels == new.isRefreshingModels
      && old.modelError == new.modelError
      && old.commandReceipt == new.commandReceipt
  }

  /// Equality for the content of the selected task. `updatedAt` is
  /// deliberately excluded: the 2-second poll ticks it for every running
  /// task, and treating that as a metadata change re-ships the whole task
  /// detail (conversation included) on every poll.
  private func taskMetadataEqual(
    _ old: BridgeDesktopTaskDetail,
    _ new: BridgeDesktopTaskDetail
  ) -> Bool {
    old.taskID == new.taskID
      && old.sessionID == new.sessionID
      && old.title == new.title
      && old.projectName == new.projectName
      && old.isTerminal == new.isTerminal
      && old.status == new.status
      && old.provider == new.provider
      && old.providerID == new.providerID
      && old.model == new.model
      && old.permissionMode == new.permissionMode
      && old.currentStep == new.currentStep
      && old.usage == new.usage
      && old.resultSummary == new.resultSummary
      && old.failureCode == new.failureCode
      && old.failureReason == new.failureReason
      && old.failureNextAction == new.failureNextAction
      && old.failureDiagnostic == new.failureDiagnostic
      && old.changedFiles == new.changedFiles
      && old.activity == new.activity
      && old.canInterrupt == new.canInterrupt
      && old.canStop == new.canStop
      && old.canSteer == new.canSteer
      && old.permissionRemediation == new.permissionRemediation
      && old.turnCount == new.turnCount
      && old.canResume == new.canResume
      && old.canRestart == new.canRestart
      && old.queuePosition == new.queuePosition
      && old.queueOccupantTaskID == new.queueOccupantTaskID
      && old.queueRequestedAt == new.queueRequestedAt
      && old.handoffPrompt == new.handoffPrompt
      && old.handoffProviders == new.handoffProviders
  }

  private func conversationPatch(
    from old: BridgeDesktopTaskDetail,
    to new: BridgeDesktopTaskDetail
  ) -> BridgeDesktopUIStatePatch.Change? {
    let oldByID = Dictionary(uniqueKeysWithValues: old.conversation.map { ($0.id, $0) })
    let newByID = Dictionary(uniqueKeysWithValues: new.conversation.map { ($0.id, $0) })
    let oldIDs = old.conversation.map(\.id)
    let newIDs = new.conversation.map(\.id)
    let commonOldIDs = oldIDs.filter { newByID[$0] != nil }
    let commonNewIDs = newIDs.filter { oldByID[$0] != nil }
    let removedIDs = oldIDs.filter { newByID[$0] == nil }
    let hasInsertions = newIDs.count > commonOldIDs.count
    let orderChanged =
      commonOldIDs != commonNewIDs
      || (hasInsertions && !newIDs.starts(with: oldIDs))

    if orderChanged {
      return .conversation(
        taskID: new.taskID,
        mode: .replace,
        entries: new.conversation,
        state: new.conversationState
      )
    }

    let changedEntries = new.conversation.filter { newEntry in
      oldByID[newEntry.id] != newEntry
    }
    guard
      !changedEntries.isEmpty || !removedIDs.isEmpty
        || old.conversationState != new.conversationState
    else { return nil }
    return .conversation(
      taskID: new.taskID,
      mode: .upsert,
      entries: changedEntries,
      removedIDs: removedIDs,
      state: new.conversationState
    )
  }

  private func rowsPatch<Row: Equatable>(
    old: [Row],
    new: [Row],
    id: KeyPath<Row, String>
  ) -> (BridgeDesktopUIStatePatch.Change.CollectionMode, [Row], [String]) {
    let oldIDs = old.map { $0[keyPath: id] }
    let newIDs = new.map { $0[keyPath: id] }
    guard oldIDs.filter({ newIDs.contains($0) }) == newIDs.filter({ oldIDs.contains($0) }) else {
      return (.replace, new, [])
    }
    let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0[keyPath: id], $0) })
    let rows = new.filter { oldByID[$0[keyPath: id]] != $0 }
    let removed = oldIDs.filter { !newIDs.contains($0) }
    return (.upsert, rows, removed)
  }
}

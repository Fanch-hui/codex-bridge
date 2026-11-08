import BridgeDesktopUI
import BridgeMCP
import BridgeServiceAppCore

/// One memoized page product, reused while the inputs the page builder reads stay equal.
@MainActor
final class BridgeDesktopUIStateSlot<Input: Equatable, Output> {
  private var stored: (input: Input, output: Output)?
  private(set) var rebuildCount = 0

  func value(for input: Input, build: () -> Output) -> Output {
    if let stored, stored.input == input { return stored.output }
    let output = build()
    stored = (input, output)
    rebuildCount += 1
    return output
  }
}

/// Page-level memo for `BridgeDesktopUIStateBuilder`, owned by the host that rebuilds the
/// desktop state, so a streamed conversation update re-derives only what actually changed.
///
/// Keys live in `BridgeDesktopUIStateCacheInputs`; each lists every model value its page
/// builder reads, so a hit always yields the product an uncached build would produce.
@MainActor
final class BridgeDesktopUIStateCache {
  let connections = BridgeDesktopUIStateSlot<
    DesktopConnectionsInput, BridgeDesktopConnectionsState
  >()
  let overview = BridgeDesktopUIStateSlot<DesktopOverviewInput, BridgeDesktopOverviewState>()
  let projects = BridgeDesktopUIStateSlot<DesktopProjectsInput, BridgeDesktopProjectsState>()
  let logs = BridgeDesktopUIStateSlot<DesktopLogsInput, BridgeDesktopLogsState>()
  let settings = BridgeDesktopUIStateSlot<DesktopSettingsInput, BridgeDesktopSettingsState>()
  let workbenchTaskRows = BridgeDesktopUIStateSlot<
    DesktopTaskRowsInput, [BridgeDesktopTaskRow]
  >()

  private var knownTasks: [MCPServiceTaskSnapshot]?
  private var revision = 0
  private var sessionsRevision = -1
  private var sortedSessions: [WorkbenchSessionItem] = []

  /// A counter that changes exactly when the task list content changes, so pages key on it
  /// instead of comparing the whole list again.
  func tasksRevision(for tasks: [MCPServiceTaskSnapshot]) -> Int {
    if knownTasks != tasks {
      knownTasks = tasks
      revision &+= 1
    }
    return revision
  }

  /// Sessions of every project, newest first. The workbench lists them all and the project
  /// page filters them, so grouping and sorting run once per task-list change.
  func sessions(for tasks: [MCPServiceTaskSnapshot]) -> [WorkbenchSessionItem] {
    let current = tasksRevision(for: tasks)
    if sessionsRevision != current {
      sortedSessions = WorkbenchSessionCatalog.sessions(tasks: tasks)
        .sorted { $0.latestTask.updatedAt > $1.latestTask.updatedAt }
      sessionsRevision = current
    }
    return sortedSessions
  }
}

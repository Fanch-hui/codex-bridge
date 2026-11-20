import BridgeACP
import BridgeServiceCore
import Foundation

/// Drives the rounds of subagents from the ledger: it decides when a queued round may start,
/// dispatches it, follows the task, releases what the round held and hands results to the
/// controller. The rules themselves live in `SubagentRoundPlanner`; this actor only reads the
/// world, asks the planner and applies the answer through the ports.
///
/// - Decisions are serial per root (`withLane`) and independent between roots. A lane is held for
///   short reads and compare-and-set writes only: the slow dispatch runs in its own task outside
///   the lane and takes the lane again just to record its outcome.
/// - A pass is triggered by `kick`: a new round, an acknowledged result, a finished dispatch, a
///   lease or reservation change. While a root has work in flight a timer re-runs it about every
///   second, so waits on dependencies, capacity and merges resolve without further events.
/// - Every ledger write is a compare-and-set on the phase; a mismatch means another path got
///   there first, and the pass runs again on fresh data.
actor SubagentRoundScheduler {
  struct Configuration: Sendable {
    /// `nil` disables the timer; tests call `tick()` themselves.
    var tickInterval: Duration? = .seconds(1)
    var retentionInterval: Duration? = .seconds(600)
    /// Service startup reconciles stored state before a controlling adapter is available.
    /// Adapter-dependent work waits for `adapterStarted`.
    var adapterAvailable = true
  }

  struct LiveDispatch {
    let key: SubagentRoundKey
    let task: Task<Void, Never>
  }

  struct SendingRequest {
    let key: SubagentRoundKey
    let fingerprint: String
    let task: Task<SubagentSendOutcome, any Error>
  }

  let ledger: any SubagentRoundLedger
  let tasks: any SubagentTaskPort
  let workspace: any SubagentWorkspacePort
  let leases: any SubagentLeasePort
  let roots: any SubagentRootPort
  let events: any SubagentEventSink
  let configuration: Configuration
  let now: @Sendable () -> Date
  /// Text for an error that becomes a failure reason shown to the controlling model.
  let describe: @Sendable (any Error) -> String

  private var lanes: [String: AsyncMutex] = [:]
  /// The dispatch each child is making right now, by child ID. One per child at most.
  var live: [String: LiveDispatch] = [:]
  /// Sends being persisted or delivered, by child and request.
  var sending: [String: SendingRequest] = [:]
  var held: Set<String> = []
  var announced: [SubagentRoundKey: String] = [:]
  var announcedDependencies: [SubagentRoundKey: String] = [:]
  private var passes: [String: Task<Void, Never>] = [:]
  private var dirty: Set<String> = []
  private var watched: Set<String> = []
  private var reports: [String: String] = [:]
  private var tickTask: Task<Void, Never>?
  private var retentionTask: Task<Void, Never>?
  private var adapterRecoveryTask: Task<Void, Never>?
  private var isStarted = false
  private(set) var isShutDown = false
  /// Leases, root holds, dispatch and delivery wait for the adapter.
  private(set) var adapterReady: Bool
  /// The undelivered results the adapter was told about, by root.
  private var announcedResults: [String: Set<SubagentRoundKey>] = [:]
  private var resultNotices: Set<String> = []

  init(
    ledger: any SubagentRoundLedger, tasks: any SubagentTaskPort,
    workspace: any SubagentWorkspacePort, leases: any SubagentLeasePort,
    roots: any SubagentRootPort, events: any SubagentEventSink,
    configuration: Configuration = Configuration(),
    now: @escaping @Sendable () -> Date = { Date() },
    describe: @escaping @Sendable (any Error) -> String = { String(describing: $0) }
  ) {
    self.ledger = ledger
    self.tasks = tasks
    self.workspace = workspace
    self.leases = leases
    self.roots = roots
    self.events = events
    self.configuration = configuration
    self.now = now
    self.describe = describe
    adapterReady = configuration.adapterAvailable
  }

  static func leaseOwner(_ key: SubagentRoundKey) -> String {
    "external:\(key.childID):\(key.requestID)"
  }

  static func holdID(rootID: String) -> String { "bridge-rounds:\(rootID)" }

  // MARK: - Lifecycle

  /// Picks up what a previous run left behind: runs a pass for every root that still has work
  /// and, when the adapter is running, re-creates the leases of dispatched rounds first.
  func start() async throws {
    guard !isStarted, !isShutDown else { return }
    isStarted = true
    do {
      let roots = try await ledger.openRoots()
      if adapterReady {
        // An adapter can call startup from its import handshake. Awaiting a callback
        // into that adapter here would deadlock the handshake.
        adapterRecoveryTask = Task { [self] in
          for rootID in roots {
            await recoverLeases(rootID: rootID)
            kick(rootID)
          }
        }
      } else {
        for rootID in roots { kick(rootID) }
      }
    } catch {
      isStarted = false
      throw error
    }
    startRetention()
  }

  /// Resumes adapter-dependent work after startup or restart without blocking the handshake.
  func adapterStarted() {
    guard !isShutDown, !adapterReady else { return }
    adapterReady = true
    adapterRecoveryTask = Task { [self] in await recoverOpenRoots() }
  }

  /// The adapter is going away; what it held (root holds, leases) goes with it.
  func adapterStopped() {
    adapterReady = false
    held = []
    announcedResults = [:]
    resultNotices = []
  }

  private func recoverOpenRoots() async {
    do {
      for rootID in try await ledger.openRoots() {
        await recoverLeases(rootID: rootID)
        kick(rootID)
      }
    } catch {
      await reportOnce("recover", rootID: "", message: describe(error))
    }
  }

  /// Cancels the timers, passes and dispatches and waits for the ones in flight. A dispatch that
  /// is cancelled records its round as unconfirmed, which the next start probes.
  func shutdown() async {
    guard !isShutDown else { return }
    isShutDown = true
    tickTask?.cancel()
    retentionTask?.cancel()
    adapterRecoveryTask?.cancel()
    var running: [Task<Void, Never>] = Array(passes.values) + live.values.map(\.task)
    running += [tickTask, retentionTask, adapterRecoveryTask].compactMap { $0 }
    let sends = Array(sending.values.map(\.task))
    for task in running { task.cancel() }
    for task in sends { task.cancel() }
    for task in running { await task.value }
    for task in sends { _ = try? await task.value }
    tickTask = nil
    retentionTask = nil
    adapterRecoveryTask = nil
  }

  /// Waits until no pass or dispatch is in flight. For tests and orderly shutdown.
  func idle() async {
    await adapterRecoveryTask?.value
    while true {
      let pending = Array(passes.values) + live.values.map(\.task)
      guard !pending.isEmpty else { return }
      for task in pending { await task.value }
    }
  }

  /// Waits until no pass is running or requested; a dispatch in progress is not waited for.
  func settlePasses() async {
    await adapterRecoveryTask?.value
    while !passes.isEmpty {
      for task in Array(passes.values) { await task.value }
    }
  }

  // MARK: - Triggering

  /// Asks for a pass over the root. Coalesced: while a pass runs, one more follows it.
  func kick(_ rootID: String) {
    guard !isShutDown else { return }
    watched.insert(rootID)
    ensureTicking()
    guard passes[rootID] == nil else {
      dirty.insert(rootID)
      return
    }
    passes[rootID] = Task { [self] in await drain(rootID) }
  }

  /// One timer step: runs a pass for every root that has work in flight. Returns whether the
  /// timer should keep going; it stops when no root needs it.
  @discardableResult
  func tick() -> Bool {
    guard !isShutDown, !watched.isEmpty else {
      tickTask = nil
      return false
    }
    for rootID in watched.sorted() { kick(rootID) }
    return true
  }

  func watch(_ rootID: String, needsTimer: Bool) {
    if needsTimer { watched.insert(rootID) } else { watched.remove(rootID) }
  }

  private func ensureTicking() {
    guard tickTask == nil, let interval = configuration.tickInterval else { return }
    tickTask = Task { [self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: interval) } catch { return }
        guard tick() else { return }
      }
    }
  }

  private func drain(_ rootID: String) async {
    repeat {
      dirty.remove(rootID)
      do {
        try await withLane(rootID) { try await pass(rootID) }
        clearReport("pass:\(rootID)")
        await announceResultsIfNeeded(rootID)
      } catch is CancellationError {
        break
      } catch {
        await reportOnce("pass:\(rootID)", rootID: rootID, message: describe(error))
      }
    } while dirty.contains(rootID) && !isShutDown
    passes[rootID] = nil
  }

  /// Notifies outside the lane: the adapter collects results with `pending`, which takes the
  /// lane. A notice the adapter did not accept is repeated by the next pass.
  private func announceResultsIfNeeded(_ rootID: String) async {
    guard resultNotices.remove(rootID) != nil, adapterReady else { return }
    if !(await roots.announceResults(rootID: rootID)) { announcedResults[rootID] = nil }
  }

  /// Remembers the results of the root that wait for delivery; a new one asks for a notice.
  func noteResults(_ planner: SubagentRoundPlanner) {
    let rootID = planner.rootID
    let waiting = Set(planner.pendingDeliveries(liveChildren: Set(live.keys)).map(\.key))
    let known = announcedResults[rootID] ?? []
    announcedResults[rootID] = waiting.isEmpty ? nil : waiting
    if !waiting.subtracting(known).isEmpty { resultNotices.insert(rootID) }
  }

  // MARK: - Serialization and diagnostics

  func withLane<T>(_ rootID: String, _ body: () async throws -> T) async rethrows -> T {
    let lane = lanes[rootID] ?? AsyncMutex()
    lanes[rootID] = lane
    await lane.acquire()
    defer { lane.release() }
    return try await body()
  }

  /// Reports a message once until the condition clears, so a persistent failure does not repeat
  /// every second.
  func reportOnce(_ key: String, rootID: String, message: String) async {
    guard reports[key] != message else { return }
    reports[key] = message
    await events.report(rootID: rootID, message: message)
  }

  func clearReport(_ key: String) { reports[key] = nil }

  // MARK: - Live state

  func liveRequestIDs() -> [String: String] { live.mapValues(\.key.requestID) }

  func isSending(_ key: SubagentRoundKey) -> Bool {
    sending[Self.sendingID(key)] != nil
  }

  static func sendingID(_ key: SubagentRoundKey) -> String {
    key.rootID + "\0" + key.childID + "\0" + key.requestID
  }

  private func startRetention() {
    guard let interval = configuration.retentionInterval else { return }
    retentionTask = Task { [self] in
      while !Task.isCancelled {
        await retire()
        do { try await Task.sleep(for: interval) } catch { return }
      }
    }
  }

  private func recoverLeases(rootID: String) async {
    do {
      try await withLane(rootID) {
        for round in try await ledger.rounds(rootID: rootID) where Self.needsLeaseRecovery(round) {
          try await leases.recover(rootID: rootID, ownerID: Self.leaseOwner(round.key))
        }
      }
    } catch {
      await reportOnce("recover:\(rootID)", rootID: rootID, message: describe(error))
    }
  }

  /// A dispatched shared writer owns a task-long lease that must exist again after a restart.
  static func needsLeaseRecovery(_ round: SubagentRound) -> Bool {
    round.leaseHeld && !round.isSteer && round.writeScope != .tool
      && round.workspaceMode == .shared
      && [.dispatching, .unknown, .running].contains(round.phase)
  }

  /// Removes old finished rounds of every root (7 days after they were finished and delivered).
  func retire() async {
    do {
      for rootID in try await ledger.allRoots() {
        try await withLane(rootID) {
          let busy = Set(live.values.map(\.key) + sending.values.map(\.key))
          _ = try await ledger.retire(rootID: rootID, now: now(), busy: busy)
        }
      }
    } catch is CancellationError {
      return
    } catch {
      await reportOnce("retention", rootID: "", message: describe(error))
    }
  }
}

import BridgeServiceCore
import Foundation

extension SubagentRoundScheduler {
  /// One decision over a root, under its lane. The order matters: the root is held first so it
  /// cannot end under a dispatch, finished tasks are settled and unconfirmed dispatches resolved
  /// before anything new starts, and what a round no longer needs is released before capacity is
  /// handed out again.
  func pass(_ rootID: String) async throws {
    let generation = adapterReady ? adapterGeneration : nil
    var rounds = try await ledger.rounds(rootID: rootID)
    guard !rounds.isEmpty else {
      watch(rootID, needsTimer: false)
      return
    }
    let snapshots = await readSnapshots(rootID: rootID, rounds: Self.snapshotTargets(rounds))
    try await recoverLeases(rootID: rootID, rounds: rounds, generation: generation)
    // Holding the root and deciding whether it is stopped are engine calls.
    let stopped =
      adapterIsReady(generation: generation) ? try await assertRoot(rootID, rounds: rounds) : false
    let planner = SubagentRoundPlanner(rootID: rootID, rounds: rounds, snapshots: snapshots)
    await settleFinishedTasks(planner)
    await resolveUnconfirmed(planner, rootStopped: stopped)
    rounds = try await ledger.rounds(rootID: rootID)
    let current = SubagentRoundPlanner(rootID: rootID, rounds: rounds, snapshots: snapshots)
    await releaseUnneeded(current)
    if adapterIsReady(generation: generation) {
      if stopped {
        await cancelQueued(rounds)
      } else {
        await scheduleQueued(current)
      }
    }
    // Rounds that ended during scheduling (failed or cancelled) give back what they held now.
    rounds = try await ledger.rounds(rootID: rootID)
    let final = SubagentRoundPlanner(rootID: rootID, rounds: rounds, snapshots: snapshots)
    await releaseUnneeded(final)
    rounds = try await ledger.rounds(rootID: rootID)
    if adapterIsReady(generation: generation) {
      try await releaseRootIfIdle(rootID, rounds: rounds)
      noteResults(final)
    }
    watch(rootID, needsTimer: Self.needsTimer(rounds, adapterReady: adapterReady))
  }

  // MARK: - Root

  /// Keeps the root open while it has subagent work. Returns whether the root is stopped.
  private func assertRoot(_ rootID: String, rounds: [SubagentRound]) async throws -> Bool {
    if try await roots.isStopped(rootID: rootID) {
      try await dropHold(rootID)
      return true
    }
    guard Self.needsRoot(rounds) else { return false }
    switch try await roots.hold(rootID: rootID, holdID: Self.holdID(rootID: rootID)) {
    case .held:
      held.insert(rootID)
      return false
    case .stopped:
      held.remove(rootID)
      return true
    }
  }

  private func releaseRootIfIdle(_ rootID: String, rounds: [SubagentRound]) async throws {
    guard held.contains(rootID), !Self.needsRoot(rounds) else { return }
    try await dropHold(rootID)
  }

  private func dropHold(_ rootID: String) async throws {
    guard held.contains(rootID) else { return }
    try await roots.release(rootID: rootID, holdID: Self.holdID(rootID: rootID))
    held.remove(rootID)
  }

  /// The root has to stay open for rounds the scheduler still drives.
  static func needsRoot(_ rounds: [SubagentRound]) -> Bool {
    rounds.contains {
      !$0.isSteer && [.queued, .dispatching, .unknown, .running].contains($0.phase)
    }
  }

  /// Rounds that need the periodic recheck: in flight, or still holding something to release.
  /// Without the controlling adapter a queued round waits for it and a lease cannot be released, so neither
  /// is rechecked.
  static func needsTimer(_ rounds: [SubagentRound], adapterReady: Bool = true) -> Bool {
    let inFlight: Set<SubagentRoundPhase> =
      adapterReady
      ? [.queued, .dispatching, .unknown, .running] : [.dispatching, .unknown, .running]
    return rounds.contains {
      inFlight.contains($0.phase) || $0.reservationHeld || (adapterReady && $0.leaseHeld)
    }
  }

  // MARK: - Snapshots

  /// The rounds whose task state a decision may depend on: those running, the targets of queued
  /// rounds' dependencies and previous rounds, and the latest run of a child that has a queued
  /// round. Everything else is read on demand.
  static func snapshotTargets(_ rounds: [SubagentRound]) -> [SubagentRound] {
    var keys = Set<SubagentRoundKey>()
    func find(_ childID: String, _ requestID: String) -> SubagentRound? {
      rounds.first { $0.key.childID == childID && $0.key.requestID == requestID }
    }
    for round in rounds where !round.isSteer && round.phase == .running { keys.insert(round.key) }
    for round in rounds where round.phase == .queued {
      for dependency in round.dependencies {
        if let target = find(dependency.childID, dependency.requestID) { keys.insert(target.key) }
      }
      let latest = rounds.last {
        $0.key.childID == round.key.childID && $0.taskID != nil && !$0.isSteer
      }
      if let latest { keys.insert(latest.key) }
      if let id = round.previousRequestID, let previous = find(round.key.childID, id) {
        keys.insert(previous.key)
      }
    }
    return rounds.filter { keys.contains($0.key) && $0.taskID != nil }
  }

  /// Reads the snapshots of the given rounds. A failed read leaves the snapshot out; the planner
  /// then keeps the dependent decision open, and the failure is reported once.
  func readSnapshots(rootID: String, rounds: [SubagentRound]) async -> [SubagentTaskSnapshot] {
    await read(rootID: rootID, rounds: rounds) {
      SubagentTaskView(
        snapshot: try await tasks.snapshot(
          rootID: $0.key.rootID, childID: $0.key.childID, taskID: $1),
        fields: [:])
    }.map(\.view.snapshot)
  }

  /// `readSnapshots` with the fields the page lists for each task.
  func readViews(rootID: String, rounds: [SubagentRound]) async -> [(
    round: SubagentRound, view: SubagentTaskView
  )] {
    await read(rootID: rootID, rounds: rounds) {
      try await tasks.view(rootID: $0.key.rootID, childID: $0.key.childID, taskID: $1)
    }
  }

  private func read(
    rootID: String, rounds: [SubagentRound],
    _ fetch: (SubagentRound, String) async throws -> SubagentTaskView
  ) async -> [(round: SubagentRound, view: SubagentTaskView)] {
    var views: [(round: SubagentRound, view: SubagentTaskView)] = []
    for round in rounds {
      guard let taskID = round.taskID else { continue }
      let reportKey = "snapshot:\(taskID)"
      do {
        let view = try await fetch(round, taskID)
        clearReport(reportKey)
        views.append((round, view))
        await announceUpdate(round, view.snapshot)
      } catch is CancellationError {
        return views
      } catch {
        await reportOnce(reportKey, rootID: rootID, message: describe(error))
      }
    }
    return views
  }

  // MARK: - Settling

  /// A running round whose task finished becomes `settled`; the controller picks its result up
  /// through `pending`.
  private func settleFinishedTasks(_ planner: SubagentRoundPlanner) async {
    for round in planner.rounds where round.phase == .running && planner.isTerminal(round) {
      await attempt(round, "settle") { _ = try await transition(round, to: .settled) }
    }
  }

  static func reportKey(_ kind: String, _ round: SubagentRound) -> String {
    "\(kind):\(round.key.childID):\(round.key.requestID)"
  }

  /// Runs one round's step; an error is reported (once, until the step works again) and does not
  /// stop the other rounds.
  func attempt(_ round: SubagentRound, _ kind: String, _ step: () async throws -> Void) async {
    let key = Self.reportKey(kind, round)
    do {
      try await step()
      clearReport(key)
    } catch is CancellationError {
      return
    } catch {
      await reportOnce(key, rootID: round.key.rootID, message: describe(error))
    }
  }

  /// Applies a compare-and-set on the round. Returns the stored round, or nil when another path
  /// changed it first, in which case a new pass is requested.
  func transition(
    _ round: SubagentRound, to next: SubagentRoundPhase? = nil,
    _ mutate: @Sendable (inout SubagentRound) throws -> Void = { _ in }
  ) async throws -> SubagentRound? {
    switch try await ledger.update(round.key, expected: round.phase, to: next, mutate: mutate) {
    case .updated(let stored):
      return stored
    case .phaseMismatch, .notFound:
      kick(round.key.rootID)
      return nil
    }
  }
}

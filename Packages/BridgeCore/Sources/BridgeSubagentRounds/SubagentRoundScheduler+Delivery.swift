import BridgeACP
import BridgeServiceCore
import Foundation

extension SubagentRoundScheduler {
  // MARK: - Pending results

  /// The results and failure notices the controller still has to deliver, oldest first. A round
  /// that failed before it got a task is delivered like a finished one: it has no task to
  /// acknowledge, so `acknowledge` works without a task ID. While the root is stopped nothing is
  /// delivered, except the rounds in `awaiting`: the controlling adapter delivers the first result of a child
  /// itself and has to be told about it even then. A result that cannot be described this round
  /// is reported in `skipped` and comes back next round, so it never holds back the others.
  package func pending(rootID: String, awaiting: Set<SubagentRoundKey> = []) async throws
    -> SubagentPendingBatch
  {
    try await withLane(rootID) { try await collectPending(rootID: rootID, awaiting: awaiting) }
  }

  private func collectPending(rootID: String, awaiting: Set<SubagentRoundKey>) async throws
    -> SubagentPendingBatch
  {
    var batch = SubagentPendingBatch()
    batch.stopped = try await roots.isStopped(rootID: rootID)
    guard !batch.stopped || !awaiting.isEmpty else { return batch }
    let rounds = try await ledger.rounds(rootID: rootID)
    batch.hasUnfinished = rounds.contains { !SubagentRoundRetention.isFinished($0) }
    let snapshots = await readSnapshots(rootID: rootID, rounds: Self.snapshotTargets(rounds))
    let planner = SubagentRoundPlanner(rootID: rootID, rounds: rounds, snapshots: snapshots)
    let deliveries = planner.pendingDeliveries(liveChildren: Set(live.keys))
    for delivery in deliveries where !batch.stopped || awaiting.contains(delivery.key) {
      do {
        guard try await settledIfNeeded(delivery, planner: planner) else { continue }
        batch.results.append(try await deliverable(delivery, planner: planner))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        batch.skipped.append(.init(key: delivery.key, message: describe(error)))
      }
    }
    return batch
  }

  /// A task that finished while its round still says `running` is settled first.
  private func settledIfNeeded(_ delivery: SubagentPendingDelivery, planner: SubagentRoundPlanner)
    async throws -> Bool
  {
    guard delivery.needsSettle else { return true }
    guard let round = planner.rounds.first(where: { $0.key == delivery.key }) else { return false }
    return try await transition(round, to: .settled) != nil
  }

  private func deliverable(_ delivery: SubagentPendingDelivery, planner: SubagentRoundPlanner)
    async throws -> SubagentPendingResult
  {
    guard let round = planner.rounds.first(where: { $0.key == delivery.key }) else {
      throw SubagentSchedulerError.unknownRound
    }
    let taskID: String?
    let result: SubagentTaskResult
    switch delivery.outcome {
    case .task(let id):
      taskID = id
      result = try await tasks.result(of: delivery.key, taskID: id)
    case .failure(let notice):
      taskID = nil
      result = SubagentTaskResult(state: "failed", error: notice)
    }
    return SubagentPendingResult(
      key: delivery.key, taskID: taskID, result: result, parentSessionID: round.parentSessionID,
      kind: round.kind, label: round.options.label, origin: round.options.origin,
      childCreatedAt: round.childCreatedAt)
  }

  // MARK: - Acknowledgement

  /// Records that the controller delivered the result of a round. Idempotent. Also keeps the
  /// older result bookkeeping in step (in the ledger's transaction). A finished round unblocks
  /// the next queued round of its child, so the root is looked at again.
  package func acknowledge(rootID: String, childID: String, requestID: String, taskID: String?)
    async throws
  {
    let key = SubagentRoundKey(rootID: rootID, childID: childID, requestID: requestID)
    try await withLane(rootID) {
      let rounds = try await ledger.rounds(rootID: rootID)
      guard let round = rounds.first(where: { $0.key == key }) else {
        throw SubagentSchedulerError.unknownRound
      }
      guard taskID == nil || round.taskID == taskID else {
        throw SubagentSchedulerError.taskMismatch
      }
      guard round.phase != .running else { throw SubagentSchedulerError.notFinished }
      switch try await ledger.markDelivered(key) {
      case .updated: break
      case .notFound: throw SubagentSchedulerError.unknownRound
      case .phaseMismatch: throw SubagentSchedulerError.notFinished
      }
    }
    kick(rootID)
  }

  // MARK: - Listing

  /// Every round of the root and the latest round of each child with its current task state.
  package func list(rootID: String) async throws -> SubagentRoundList {
    let rounds = try await ledger.rounds(rootID: rootID)
    let latest = Self.latestRuns(rounds)
    var sources = latest.compactMap { Self.latestTaskRun(of: $0.key.childID, in: rounds) }
    var seen = Set(sources.map(\.key))
    for target in Self.snapshotTargets(rounds) where seen.insert(target.key).inserted {
      sources.append(target)
    }
    let views = await readViews(rootID: rootID, rounds: sources)
    let planner = SubagentRoundPlanner(
      rootID: rootID, rounds: rounds, snapshots: views.map(\.view.snapshot))
    let children = latest.map { round in
      let source = Self.latestTaskRun(of: round.key.childID, in: rounds)
      let view = views.first { $0.round.key == source?.key }?.view
      return Self.summary(
        of: round, snapshot: view?.snapshot, fields: view?.fields ?? [:], rounds: rounds,
        planner: planner)
    }
    return SubagentRoundList(
      rounds: rounds, children: children,
      hasUnfinished: rounds.contains { !SubagentRoundRetention.isFinished($0) })
  }

  /// The latest round of the child that has a task and is not a steer.
  static func latestTaskRun(of childID: String, in rounds: [SubagentRound]) -> SubagentRound? {
    rounds.last { $0.key.childID == childID && $0.taskID != nil && !$0.isSteer }
  }

  /// The latest round of each child that is not a steer, in the order the children appeared.
  static func latestRuns(_ rounds: [SubagentRound]) -> [SubagentRound] {
    var order: [String] = []
    var latest: [String: SubagentRound] = [:]
    for round in rounds where !round.isSteer {
      if latest[round.key.childID] == nil { order.append(round.key.childID) }
      latest[round.key.childID] = round
    }
    return order.compactMap { latest[$0] }
  }

  private static func summary(
    of round: SubagentRound, snapshot: SubagentTaskSnapshot?, fields: [String: ACPJSONValue],
    rounds: [SubagentRound], planner: SubagentRoundPlanner
  ) -> SubagentChildSummary {
    let queued = rounds.filter {
      $0.key.childID == round.key.childID && $0.key != round.key && $0.phase == .queued
    }
    let waitingFor =
      round.phase == .queued
      ? round.dependencies.filter { dependency in
        switch planner.dependencyReadiness(of: [dependency]) {
        case .waiting, .inconsistent: true
        case .ready, .failed: false
        }
      } : []
    return SubagentChildSummary(
      childID: round.key.childID, installationID: round.installationID,
      requestID: round.key.requestID, phase: round.phase, taskID: round.taskID,
      state: planner.state(of: round)?.rawValue ?? fallbackState(round.phase),
      workspaceMode: snapshot?.workspaceMode ?? round.workspaceMode,
      workspaceStatus: snapshot?.workspaceStatus?.rawValue, access: round.access,
      label: round.options.label, model: fields["model"]?.stringValue ?? round.options.model,
      origin: origin(ofChild: round.key.childID, in: rounds),
      childCreatedAt: round.childCreatedAt, waitingReason: round.waitingReason,
      waitingFor: waitingFor,
      queuedCount: queued.count, snapshot: fields)
  }

  /// The first round of a child says who started it.
  private static func origin(ofChild childID: String, in rounds: [SubagentRound])
    -> SubagentRoundOrigin
  {
    rounds.first { $0.key.childID == childID && !$0.isSteer }?.options.origin ?? .model
  }

  private static func fallbackState(_ phase: SubagentRoundPhase) -> String {
    switch phase {
    case .settled: SubagentTaskState.completed.rawValue
    case .running: SubagentTaskState.running.rawValue
    default: SubagentTaskState.created.rawValue
    }
  }
}

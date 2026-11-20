import BridgeServiceCore
import Foundation

extension SubagentRoundScheduler {
  // MARK: - Start

  /// Records the first round of a new child as queued; the scheduler dispatches it when its
  /// dependencies are met and capacity allows. Answers at once.
  func start(_ request: SubagentStartRequest) async throws -> SubagentStartResult {
    guard !isShutDown else { throw SubagentSchedulerError.shutDown }
    let result = try await withLane(request.rootID) { try await recordStart(request) }
    kick(request.rootID)
    return result
  }

  private func recordStart(_ request: SubagentStartRequest) async throws -> SubagentStartResult {
    let rounds = try await ledger.rounds(rootID: request.rootID)
    let own = rounds.filter { $0.key.childID == request.childID }
    try await requireChildAvailable(
      request.childID, rootID: request.rootID, hasRounds: !own.isEmpty)
    // A child is started once; a new request ID for an existing child is a continuation.
    guard own.isEmpty || own.contains(where: { $0.key.requestID == request.requestID }) else {
      throw SubagentRoundRejection.alreadyAdmitted
    }
    let planner = SubagentRoundPlanner(rootID: request.rootID, rounds: rounds)
    let dependencies = try planner.resolveDependencies(childIDs: request.dependsOn)
    let draft = Self.startDraft(request, dependencies: dependencies, createdAt: now())
    switch try planner.admitStart(draft) {
    case .existing:
      return SubagentStartResult(created: false)
    case .create(let draft):
      return SubagentStartResult(created: try await ledger.insert(draft).created)
    }
  }

  private static func startDraft(
    _ request: SubagentStartRequest, dependencies: [SubagentRoundDependency], createdAt: Date
  ) -> SubagentRoundDraft {
    let fingerprint = SubagentRoundFingerprint.start(
      rootID: request.rootID, childID: request.childID, installationID: request.installationID,
      requestID: request.requestID, options: request.options, access: request.access,
      prompt: request.prompt, dependencies: dependencies)
    return SubagentRoundDraft(
      key: SubagentRoundKey(
        rootID: request.rootID, childID: request.childID, requestID: request.requestID),
      projectID: request.projectID, parentSessionID: request.parentSessionID,
      installationID: request.installationID, kind: .start, fingerprint: fingerprint,
      prompt: request.prompt, options: request.options, access: request.access,
      dependencies: dependencies, createdAt: createdAt)
  }

  /// A child must belong to this root, and one created by the older bookkeeping has to be
  /// migrated before it can take part in rounds.
  func requireChildAvailable(_ childID: String, rootID: String, hasRounds: Bool)
    async throws
  {
    guard !hasRounds else { return }
    if try await ledger.roots(ofChild: childID).contains(where: { $0 != rootID }) {
      throw SubagentRoundRejection.wrongRoot
    }
    if try await tasks.isLegacyChild(rootID: rootID, childID: childID) {
      throw SubagentSchedulerError.legacyChildRequiresMigration(childID: childID)
    }
  }

  // MARK: - Send

  private enum SendAdmission {
    case done(SubagentSendOutcome)
    case join(Task<SubagentSendOutcome, any Error>)
  }

  /// A message to a child: steered into the running task, or queued as a continuation.
  func send(_ request: SubagentSendRequest, rootID: String) async throws -> SubagentSendOutcome {
    guard !isShutDown else { throw SubagentSchedulerError.shutDown }
    let admission = try await withLane(rootID) { try await admitSend(request, rootID: rootID) }
    switch admission {
    case .done(let outcome):
      if outcome == .queued { kick(rootID) }
      return outcome
    case .join(let task):
      return try await task.value
    }
  }

  private func admitSend(_ request: SubagentSendRequest, rootID: String) async throws
    -> SendAdmission
  {
    let rounds = try await ledger.rounds(rootID: rootID)
    let hasRounds = rounds.contains { $0.key.childID == request.childID }
    try await requireChildAvailable(request.childID, rootID: rootID, hasRounds: hasRounds)
    let targets = Self.childSnapshotTargets(rounds, childID: request.childID)
    let snapshots = await readSnapshots(rootID: rootID, rounds: targets)
    let planner = SubagentRoundPlanner(rootID: rootID, rounds: rounds, snapshots: snapshots)
    let key = SubagentRoundKey(
      rootID: rootID, childID: request.childID, requestID: request.requestID)
    let inFlight = sending[Self.sendingID(key)]
    switch try planner.admitSend(request, inFlightFingerprint: inFlight?.fingerprint) {
    case .replay(let replay):
      return .done(.replay(replay))
    case .joinInFlight:
      guard let inFlight else { return .done(.replay(.checking(deliveryUnknown: false))) }
      return .join(inFlight.task)
    case .enqueue(let draft):
      _ = try await ledger.insert(draft)
      return .done(.queued)
    case .steer(let draft, let taskID):
      return try await beginSteer(draft, taskID: taskID, prompt: request.prompt)
    }
  }

  /// The running task and the latest run of the child: what `admitSend` reads snapshots for.
  static func childSnapshotTargets(_ rounds: [SubagentRound], childID: String) -> [SubagentRound] {
    let own = rounds.filter { $0.key.childID == childID && !$0.isSteer && $0.taskID != nil }
    return own.filter { $0.phase == .running || $0.key == own.last?.key }
  }

  // MARK: - Steer

  /// Records the steer as dispatching, then delivers it outside the lane. The instruction is sent
  /// once: a failure leaves the round `unknown`, never resent.
  private func beginSteer(_ draft: SubagentRoundDraft, taskID: String, prompt: String) async throws
    -> SendAdmission
  {
    let insertion = try await ledger.insert(draft)
    guard insertion.created else { return .done(.replay(.checking(deliveryUnknown: false))) }
    let round = insertion.round
    let task = Task { [self] in try await deliverSteer(round, taskID: taskID, prompt: prompt) }
    sending[Self.sendingID(round.key)] = SendingRequest(
      key: round.key, fingerprint: draft.fingerprint, task: task)
    return .join(task)
  }

  private func deliverSteer(_ round: SubagentRound, taskID: String, prompt: String) async throws
    -> SubagentSendOutcome
  {
    defer { sending[Self.sendingID(round.key)] = nil }
    do {
      let receipt = try await tasks.steer(round, taskID: taskID, prompt: prompt)
      guard receipt.taskID == taskID else { throw SubagentSchedulerError.taskMismatch }
      _ = try await transition(round, to: .attached, { $0.taskID = taskID })
      return .steered(taskID: taskID)
    } catch {
      await markSteerUnknown(round, error)
      throw error
    }
  }

  private func markSteerUnknown(_ round: SubagentRound, _ error: any Error) async {
    let reason = String(describe(error).prefix(2_000))
    await attempt(round, "steer") {
      _ = try await transition(round, to: .unknown, { $0.dispatchError = reason })
    }
    kick(round.key.rootID)
  }

  // MARK: - Reads

  func receipt(rootID: String, childID: String, requestID: String) async throws -> SubagentReceipt {
    let rounds = try await ledger.rounds(rootID: rootID)
    let key = SubagentRoundKey(rootID: rootID, childID: childID, requestID: requestID)
    return SubagentRoundPlanner(rootID: rootID, rounds: rounds)
      .receipt(childID: childID, requestID: requestID, isSending: isSending(key))
  }

  func hasRunning(rootID: String) async throws -> Bool {
    let rounds = try await ledger.rounds(rootID: rootID)
    return SubagentRoundPlanner(rootID: rootID, rounds: rounds)
      .hasRunning(liveRequestIDs: liveRequestIDs())
  }
}

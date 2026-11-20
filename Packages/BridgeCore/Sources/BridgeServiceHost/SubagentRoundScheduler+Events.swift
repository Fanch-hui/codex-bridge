import BridgeACP
import BridgeServiceCore
import Foundation

/// The events the page and the controller already know from the Node orchestrator
/// (`subagent.started`, `.updated`, `.waiting`, `.dependencies`, `.input-unknown`), under the
/// parent session of the round. The page refreshes its subagent list on any of them.
extension SubagentRoundScheduler {
  /// A JSON object from string fields; absent values are left out.
  static func object(_ fields: [String: String?]) -> ACPJSONValue {
    .object(fields.compactMapValues { $0.map(ACPJSONValue.string) })
  }

  private func identity(of round: SubagentRound) -> [String: ACPJSONValue] {
    [
      "rootSessionID": .string(round.key.rootID),
      "parentSessionID": .string(round.parentSessionID),
      "parentSessionId": .string(round.parentSessionID),
      "childID": .string(round.key.childID), "requestID": .string(round.key.requestID),
    ]
  }

  /// A start or continuation was accepted by Bridge and has a task. A steer attaches silently.
  func announceStarted(_ round: SubagentRound, state: String) async {
    guard !round.isSteer else { return }
    var fields = identity(of: round)
    fields["installationID"] = .string(round.installationID)
    fields["state"] = .string(state)
    fields["admission"] = .string("accepted")
    if let taskID = round.taskID { fields["taskID"] = .string(taskID) }
    if let mode = round.workspaceMode { fields["workspaceMode"] = .string(mode.rawValue) }
    if let label = round.options.label { fields["label"] = .string(label) }
    fields["dependencies"] = .array(
      round.dependencies.map {
        .object(["childID": .string($0.childID), "requestID": .string($0.requestID)])
      })
    await events.emit(
      sessionID: round.parentSessionID, type: "subagent.started", payload: .object(fields))
  }

  /// A task snapshot changed since it was last announced.
  func announceUpdate(_ round: SubagentRound, _ snapshot: SubagentTaskSnapshot) async {
    let fingerprint = [
      snapshot.state.rawValue, snapshot.runID ?? "", snapshot.workspaceMode?.rawValue ?? "",
      snapshot.workspaceStatus?.rawValue ?? "", String(describing: snapshot.canSteer),
      String(describing: snapshot.canContinue),
    ].joined(separator: "|")
    guard announced[round.key] != fingerprint else { return }
    announced[round.key] = fingerprint
    var fields = identity(of: round)
    fields["taskID"] = .string(snapshot.taskID)
    fields["state"] = .string(snapshot.state.rawValue)
    if let runID = snapshot.runID { fields["runID"] = .string(runID) }
    if let mode = snapshot.workspaceMode { fields["workspaceMode"] = .string(mode.rawValue) }
    if let status = snapshot.workspaceStatus {
      fields["workspaceStatus"] = .string(status.rawValue)
    }
    await events.emit(
      sessionID: round.parentSessionID, type: "subagent.updated", payload: .object(fields))
  }

  /// A round ended without a task; the page shows it as failed.
  func announceFailure(_ round: SubagentRound) async {
    var fields = identity(of: round)
    fields["state"] = .string("failed")
    if let reason = round.failureReason { fields["error"] = .string(reason) }
    await events.emit(
      sessionID: round.parentSessionID, type: "subagent.updated", payload: .object(fields))
  }

  func announceWaiting(_ round: SubagentRound, workspaceStatus: String) async {
    await events.emit(
      sessionID: round.parentSessionID, type: "subagent.waiting",
      payload: Self.object(
        [
          "childID": round.key.childID, "requestID": round.key.requestID,
          "workspaceStatus": workspaceStatus,
        ]))
  }

  /// The dependencies a queued round still waits for changed (an empty list means all are met).
  func announceDependencies(_ round: SubagentRound, _ pending: [SubagentPendingDependency]) async {
    let list = pending.map { dependency -> ACPJSONValue in
      var fields: [String: ACPJSONValue] = [
        "childID": .string(dependency.childID), "state": .string(dependency.state.rawValue),
      ]
      if let status = dependency.workspaceStatus {
        fields["workspaceStatus"] = .string(status.rawValue)
      }
      return .object(fields)
    }
    let fingerprint = pending.map {
      "\($0.childID)|\($0.state.rawValue)|\($0.workspaceStatus?.rawValue ?? "")"
    }.joined(separator: ",")
    guard announcedDependencies[round.key] != fingerprint else { return }
    announcedDependencies[round.key] = fingerprint
    await events.emit(
      sessionID: round.parentSessionID, type: "subagent.dependencies",
      payload: .object([
        "childID": .string(round.key.childID), "requestID": .string(round.key.requestID),
        "dependencies": .array(list),
      ]))
  }
}

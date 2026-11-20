import BridgeACP
import BridgeServiceCore
import Foundation

/// The JSON of the `round.*` operations. Shapes follow the Node orchestrator's answers where one
/// existed (`send`, `receipt`, results), so the engine side can use them as they are.
enum SubagentRoundJSON {
  static func send(_ outcome: SubagentSendOutcome, childID: String) -> ACPJSONValue {
    var fields: [String: ACPJSONValue] = ["childID": .string(childID)]
    switch outcome {
    case .queued:
      fields.merge(queued) { _, new in new }
    case .steered(let taskID):
      fields.merge(accepted(taskID: taskID, delivery: .steer)) { _, new in new }
    case .replay(let replay):
      fields.merge(self.replay(replay)) { _, new in new }
    }
    return .object(fields)
  }

  private static let queued: [String: ACPJSONValue] = [
    "accepted": .bool(true), "queued": .bool(true), "delivery": .string("queue"),
  ]

  private static func accepted(taskID: String, delivery: SubagentDelivery) -> [String: ACPJSONValue]
  {
    [
      "accepted": .bool(true), "taskID": .string(taskID), "delivery": .string(delivery.rawValue),
    ]
  }

  private static func replay(_ replay: SubagentSendReplay) -> [String: ACPJSONValue] {
    switch replay {
    case .checking(let deliveryUnknown):
      var fields: [String: ACPJSONValue] = [
        "accepted": .bool(true), "state": .string("checking"),
      ]
      if deliveryUnknown { fields["reason"] = .string("delivery_unknown") }
      return fields
    case .accepted(let taskID, let delivery):
      return accepted(taskID: taskID, delivery: delivery)
    case .refused(let failed, let error):
      var fields: [String: ACPJSONValue] = [
        "accepted": .bool(false), "state": .string(failed ? "failed" : "cancelled"),
      ]
      if let error { fields["error"] = .string(error) }
      return fields
    case .queued:
      return queued
    }
  }

  static func receipt(_ receipt: SubagentReceipt) -> ACPJSONValue {
    switch receipt {
    case .notFound:
      return .object(["state": .string("notFound")])
    case .cancelled:
      return .object(["state": .string("cancelled")])
    case .queued:
      return .object(["state": .string("queued")])
    case .failed(let error):
      return .object(["state": .string("failed"), "error": error.map(ACPJSONValue.string) ?? .null])
    case .unknown(let reason, let taskID):
      var fields: [String: ACPJSONValue] = ["state": .string("unknown")]
      if let reason { fields["reason"] = .string(reason) }
      if let taskID { fields["taskID"] = .string(taskID) }
      return .object(fields)
    case .accepted(let taskID):
      var fields: [String: ACPJSONValue] = ["state": .string("accepted")]
      if let taskID { fields["taskID"] = .string(taskID) }
      return .object(fields)
    }
  }

  static func dependencies(_ readiness: SubagentDependencyReadiness) -> ACPJSONValue {
    switch readiness {
    case .ready:
      return .object(["state": .string("ready")])
    case .waiting(let pending):
      return .object([
        "state": .string("waiting"),
        "pending": .array(
          pending.map {
            var fields: [String: ACPJSONValue] = [
              "childID": .string($0.childID), "state": .string($0.state.rawValue),
            ]
            if let status = $0.workspaceStatus {
              fields["workspaceStatus"] = .string(status.rawValue)
            }
            return .object(fields)
          }),
      ])
    case .failed(let reason):
      return .object(["state": .string("failed"), "reason": .string(reason)])
    case .inconsistent(let reason):
      return .object(["state": .string("inconsistent"), "reason": .string(reason)])
    }
  }

  static func list(_ list: SubagentRoundList, rootID: String) -> ACPJSONValue {
    .object([
      "rootSessionID": .string(rootID), "hasUnfinished": .bool(list.hasUnfinished),
      "children": .array(list.children.map(child)),
      "rounds": .array(list.rounds.map(round)),
    ])
  }

  private static func child(_ child: SubagentChildSummary) -> ACPJSONValue {
    var fields: [String: ACPJSONValue] = [
      "childID": .string(child.childID), "installationID": .string(child.installationID),
      "requestID": .string(child.requestID), "phase": .string(child.phase.rawValue),
      "state": .string(child.state),
      "createdAt": .integer(Int64(child.childCreatedAt.timeIntervalSince1970 * 1_000)),
    ]
    if let taskID = child.taskID { fields["taskID"] = .string(taskID) }
    if let mode = child.workspaceMode { fields["workspaceMode"] = .string(mode.rawValue) }
    if let status = child.workspaceStatus { fields["workspaceStatus"] = .string(status) }
    if let access = child.access { fields["access"] = .string(access.rawValue) }
    if let label = child.label { fields["label"] = .string(label) }
    if let model = child.model { fields["model"] = .string(model) }
    fields["origin"] = .string(child.origin.rawValue)
    if let reason = child.waitingReason { fields["waitingReason"] = .string(reason) }
    if !child.waitingFor.isEmpty {
      fields["waitingFor"] = .array(
        child.waitingFor.map {
          .object(["childID": .string($0.childID), "requestID": .string($0.requestID)])
        })
    }
    fields["queuedCount"] = .integer(Int64(child.queuedCount))
    if !child.snapshot.isEmpty { fields["snapshot"] = .object(child.snapshot) }
    return .object(fields)
  }

  private static func round(_ round: SubagentRound) -> ACPJSONValue {
    var fields: [String: ACPJSONValue] = [
      "childID": .string(round.key.childID), "requestID": .string(round.key.requestID),
      "parentSessionID": .string(round.parentSessionID),
      "installationID": .string(round.installationID), "kind": .string(round.kind.rawValue),
      "phase": .string(round.phase.rawValue), "ordinal": .integer(round.ordinal),
      "deliveryRequired": .bool(round.deliveryRequired), "delivered": .bool(round.delivered),
      "repairConflict": .bool(round.repairConflict),
      "origin": .string(round.options.origin.rawValue),
    ]
    let optional: [(String, String?)] = [
      ("taskID", round.taskID), ("waitingReason", round.waitingReason),
      ("failureReason", round.failureReason), ("failureOrigin", round.failureOrigin?.rawValue),
      ("workspaceMode", round.workspaceMode?.rawValue), ("writeScope", round.writeScope?.rawValue),
      ("access", round.access?.rawValue), ("label", round.options.label),
    ]
    for (name, value) in optional {
      if let value { fields[name] = .string(value) }
    }
    return .object(fields)
  }

  static func pending(_ batch: SubagentPendingBatch) -> ACPJSONValue {
    var fields: [String: ACPJSONValue] = ["results": .array(batch.results.map(result))]
    if !batch.skipped.isEmpty {
      fields["skipped"] = .array(
        batch.skipped.map {
          .object([
            "childID": .string($0.key.childID), "requestID": .string($0.key.requestID),
            "error": .string($0.message),
          ])
        })
    }
    if batch.stopped { fields["stopped"] = .bool(true) }
    fields["hasUnfinished"] = .bool(batch.hasUnfinished)
    return .object(fields)
  }

  private static func result(_ pending: SubagentPendingResult) -> ACPJSONValue {
    var fields = pending.result.workspace
    fields["childID"] = .string(pending.key.childID)
    fields["requestID"] = .string(pending.key.requestID)
    fields["parentSessionID"] = .string(pending.parentSessionID)
    fields["kind"] = .string(pending.kind.rawValue)
    if let label = pending.label { fields["label"] = .string(label) }
    fields["origin"] = .string(pending.origin.rawValue)
    fields["createdAt"] = .integer(Int64(pending.childCreatedAt.timeIntervalSince1970 * 1_000))
    fields["taskID"] = pending.taskID.map(ACPJSONValue.string) ?? .null
    fields["state"] = .string(pending.result.state)
    fields["output"] = pending.result.output.map(ACPJSONValue.string) ?? .null
    fields["error"] = pending.result.error.map(ACPJSONValue.string) ?? .null
    return .object(fields)
  }
}

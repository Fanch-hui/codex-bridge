import BridgeACP
import BridgeDomain
import BridgeServiceCore
import Foundation

/// Turns the records of the earlier Node orchestrator (`bridge-subagents.json`) into ledger
/// rounds. The engine hands the file's records over once, in file order; the order decides the
/// ledger's ordinals. The mapping is a pure function of one record, so the import can be repeated.
enum SubagentRoundImport {
  /// Why a record is not imported. The raw value is what the answer reports.
  enum Skip: String, Error {
    case unknownProject = "unknown_project"
    case incomplete
    case invalid
    case conflict
  }

  static let promptPlaceholder = "(the instruction was not kept by the earlier version)"
  static let neverDispatchable =
    "The queued request of an earlier version cannot be dispatched after the upgrade; delegate again if still needed."

  /// What the record is relative to the records before it.
  struct Position {
    /// No earlier record of the same child has been seen: an unmarked record is its `start`.
    var firstOfChild: Bool
    var now: Date
  }

  static func draft(
    _ binding: [String: ACPJSONValue], rootID: String, projectID: ProjectID, at position: Position
  ) throws -> SubagentRoundDraft {
    guard let childID = string(binding, "childID"), let requestID = string(binding, "requestID"),
      let installationID = string(binding, "installationID")
    else { throw Skip.incomplete }
    let kind = roundKind(binding, firstOfChild: position.firstOfChild)
    let created = date(binding["createdAt"]) ?? position.now
    let shape = try phase(binding, kind: kind)
    let delivery = deliveryRequired(binding, kind: kind)
    let delivered =
      delivery && [.settled, .failed].contains(shape.phase) && wasDelivered(binding, shape)
    var draft = SubagentRoundDraft(
      key: SubagentRoundKey(rootID: rootID, childID: childID, requestID: requestID),
      projectID: projectID, parentSessionID: string(binding, "parentSessionID") ?? rootID,
      installationID: installationID, kind: kind, phase: shape.phase,
      fingerprint: fingerprint(binding, kind: kind, rootID: rootID),
      prompt: shape.phase.holdsPrompt && kind != .steer ? shape.prompt : nil,
      options: options(binding),
      access: string(binding, "access") == SubagentRoundAccess.readOnly.rawValue ? .readOnly : nil,
      repairConflict: binding["repairConflict"]?.boolValue == true,
      dependencies: dependencies(binding),
      previousRequestID: string(binding, "previousRequestID"),
      previousTaskID: string(binding, "previousTaskID"),
      previousRunID: string(binding, "previousRunID"),
      requestedAfterTerminal: binding["requestedAfterTerminal"]?.boolValue == true,
      taskID: shape.taskID, deliveryRequired: delivery, delivered: delivered,
      childCreatedAt: created, createdAt: created)
    draft.waitingReason = shape.phase == .queued ? string(binding, "waitingReason") : nil
    draft.dispatchError = shape.phase == .unknown ? string(binding, "dispatchError") : nil
    draft.failureReason = shape.failure?.reason
    draft.failureOrigin = shape.failure?.origin
    applyWorkspace(binding, shape: shape, kind: kind, to: &draft)
    if SubagentRoundRetention.isFinished(SubagentRound(draft: draft, ordinal: 0)) {
      draft.settledAt = date(binding["settledAt"])
    }
    return draft
  }

  // MARK: - Shape

  private struct Shape {
    var phase: SubagentRoundPhase
    var taskID: String?
    var prompt: String?
    var failure: (reason: String?, origin: SubagentFailureOrigin)?
  }

  private static let terminalStates: Set<String> = [
    "completed", "failed", "interrupted", "cancelled",
  ]

  /// The admission table of the migration: `admission` x `state` x `pendingOperation` -> phase.
  private static func phase(_ binding: [String: ACPJSONValue], kind: SubagentRoundKind) throws
    -> Shape
  {
    let admission = string(binding, "admission") ?? "accepted"
    let taskID = string(binding, "taskID")
    let prompt = string(binding, "pendingPrompt")
    let finished = terminalStates.contains(string(binding, "state") ?? "")
    if kind == .steer { return try steerShape(admission, binding: binding, taskID: taskID) }
    switch admission {
    case "waiting":
      let dispatchable = ["start", "send"].contains(string(binding, "pendingOperation") ?? "")
      guard dispatchable, let prompt else {
        return Shape(phase: .failed, failure: (neverDispatchable, .dispatch))
      }
      return Shape(phase: .queued, prompt: prompt)
    case "dispatching":
      return Shape(phase: .dispatching, taskID: taskID, prompt: prompt ?? promptPlaceholder)
    case "unknown", "delivery_unknown":
      return Shape(phase: .unknown, taskID: taskID, prompt: prompt ?? promptPlaceholder)
    case "cancelled":
      guard string(binding, "state") == "failed" else { return Shape(phase: .cancelled) }
      return Shape(
        phase: .failed, failure: (string(binding, "failureReason"), failureOrigin(binding)))
    default:
      guard let taskID else { throw Skip.incomplete }
      return Shape(phase: finished || admission == "settled" ? .settled : .running, taskID: taskID)
    }
  }

  private static func steerShape(
    _ admission: String, binding: [String: ACPJSONValue], taskID: String?
  ) throws -> Shape {
    switch admission {
    case "attached":
      guard let taskID else { throw Skip.incomplete }
      return Shape(phase: .attached, taskID: taskID)
    case "dispatching": return Shape(phase: .dispatching, taskID: taskID)
    case "delivery_unknown": return Shape(phase: .deliveryUnknown, taskID: taskID)
    case "cancelled":
      let reason = string(binding, "failureReason") ?? "The instruction was cancelled."
      return Shape(phase: .failed, failure: (reason, .input))
    default: return Shape(phase: .unknown, taskID: taskID)
    }
  }

  /// A failed record carries only a message; the notice text depends on where it came from.
  private static func failureOrigin(_ binding: [String: ACPJSONValue]) -> SubagentFailureOrigin {
    let reason = string(binding, "failureReason") ?? ""
    let dependency = reason.hasPrefix("Dependency ") || reason.hasPrefix("The previous subagent")
    return dependency ? .dependency : .dispatch
  }

  private static func roundKind(_ binding: [String: ACPJSONValue], firstOfChild: Bool)
    -> SubagentRoundKind
  {
    if string(binding, "inputKind") == "steer" { return .steer }
    switch string(binding, "pendingOperation") {
    case "start": return .start
    case "send": return .send
    default: return binding["first"]?.boolValue ?? firstOfChild ? .start : .send
    }
  }

  // MARK: - Fields

  /// A round that failed before it got a task had its notice tried in the step that failed it,
  /// and the older version never repeated it; importing it as delivered keeps it that way.
  private static func wasDelivered(_ binding: [String: ACPJSONValue], _ shape: Shape) -> Bool {
    shape.phase == .failed || binding["resultDelivered"]?.boolValue == true
  }

  private static func deliveryRequired(_ binding: [String: ACPJSONValue], kind: SubagentRoundKind)
    -> Bool
  {
    kind != .steer && binding["deliveryRequired"]?.boolValue != false
  }

  /// The older records kept the hash of the request; without one the round gets a value no real
  /// request can equal, so a repeated request with other content is refused as before.
  private static func fingerprint(
    _ binding: [String: ACPJSONValue], kind: SubagentRoundKind, rootID: String
  ) -> String {
    let stored = string(binding, kind == .start ? "requestHash" : "promptHash")
    if let stored, stored.utf8.count <= 128 { return stored }
    return SubagentRoundFingerprint.legacySend(
      prompt: [
        "legacy", rootID, string(binding, "childID") ?? "", string(binding, "requestID") ?? "",
      ]
      .joined(separator: "\0"))
  }

  private static func options(_ binding: [String: ACPJSONValue]) -> SubagentRoundOptions {
    SubagentRoundOptions(
      model: string(binding, "model"), effort: string(binding, "effort"),
      attachmentPaths: binding["attachmentPaths"]?.arrayValue?.compactMap(\.stringValue) ?? [],
      label: string(binding, "label"))
  }

  private static func dependencies(_ binding: [String: ACPJSONValue]) -> [SubagentRoundDependency] {
    (binding["dependencies"]?.arrayValue ?? []).compactMap { item in
      guard let childID = item["childID"]?.stringValue,
        let requestID = item["requestID"]?.stringValue
      else { return nil }
      return SubagentRoundDependency(childID: childID, requestID: requestID)
    }
  }

  /// Workspace and capacity flags. The older version never stored the task-long lease: it held
  /// one for every dispatched shared writer that was not read-only, tool-scoped or finished, so
  /// that is what the lease flag restores.
  private static func applyWorkspace(
    _ binding: [String: ACPJSONValue], shape: Shape, kind: SubagentRoundKind,
    to draft: inout SubagentRoundDraft
  ) {
    draft.workspaceMode = string(binding, "workspaceMode").flatMap(SubagentWorkspaceMode.init)
    draft.writeScope = string(binding, "writeScope").flatMap(SubagentWriteScope.init)
    draft.reservationHeld = binding["reservationHeld"]?.boolValue == true
    let inFlight = [.dispatching, .unknown, .running].contains(shape.phase)
    draft.leaseHeld =
      inFlight && kind != .steer && draft.workspaceMode == .shared && draft.writeScope != .tool
      && draft.access != .readOnly
  }

  // MARK: - Reading

  static func string(_ binding: [String: ACPJSONValue], _ key: String) -> String? {
    guard let value = binding[key]?.stringValue, !value.isEmpty else { return nil }
    return value
  }

  /// Milliseconds since the epoch, as `Date.now()` wrote them.
  private static func date(_ value: ACPJSONValue?) -> Date? {
    guard let millis = value?.doubleValue, millis.isFinite, millis > 0 else { return nil }
    return Date(timeIntervalSince1970: millis / 1_000)
  }
}

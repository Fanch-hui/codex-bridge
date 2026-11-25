import BridgeACP
import BridgeDomain
import BridgeServiceCore
import BridgeSubagentRounds
import Foundation

/// The `round.*` operations of `bridge/subagent`: subagent orchestration in the Swift scheduler,
/// alongside history and workspace inspection. Each one validates its input
/// and forwards to `SubagentRoundScheduler`; errors use the injected IPC projection.
extension ServiceEmbeddedDSHController {
  private static let roundOperations: Set<String> = [
    "round.start", "round.send", "round.receipt", "round.list", "round.pending", "round.ack",
    "round.stopChild", "round.cancelInput", "round.stopRoot", "round.hasRunning",
    "round.dependencies",
  ]

  func subagentRoundOperation(
    _ operation: String, payload: [String: ACPJSONValue], rootID: String, projectID: ProjectID
  ) async throws -> ACPJSONValue {
    guard Self.roundOperations.contains(operation) else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.subagent_operation")
    }
    let scheduler = try await ensureSubagentScheduler()
    switch operation {
    case "round.start":
      return try await roundStart(payload, rootID: rootID, projectID: projectID, scheduler)
    case "round.send":
      return try await roundSend(payload, rootID: rootID, scheduler)
    case "round.list":
      return SubagentRoundJSON.list(try await scheduler.list(rootID: rootID), rootID: rootID)
    case "round.pending":
      return SubagentRoundJSON.pending(
        try await scheduler.pending(
          rootID: rootID, awaiting: try Self.awaitedRounds(payload, rootID: rootID)))
    case "round.stopRoot":
      try await scheduler.stopRoot(rootID: rootID)
      return .object(["accepted": .bool(true)])
    case "round.dependencies":
      let result = try await scheduler.dependencyReadiness(
        rootID: rootID, childIDs: Self.stringList(payload, "dependsOn"),
        pinned: Self.pinnedDependencies(payload))
      var response = SubagentRoundJSON.dependencies(result.readiness).objectValue ?? [:]
      response["dependencies"] = .array(
        result.dependencies.map {
          .object(["childID": .string($0.childID), "requestID": .string($0.requestID)])
        })
      return .object(response)
    case "round.hasRunning":
      return .object(["running": .bool(try await scheduler.hasRunning(rootID: rootID))])
    default:
      return try await roundChildOperation(operation, payload: payload, rootID: rootID, scheduler)
    }
  }

  /// The operations that name a child.
  private func roundChildOperation(
    _ operation: String, payload: [String: ACPJSONValue], rootID: String,
    _ scheduler: SubagentRoundScheduler
  ) async throws -> ACPJSONValue {
    let childID = try Self.requiredString(payload, "childID")
    switch operation {
    case "round.receipt":
      let requestID = try Self.requiredString(payload, "requestID")
      return SubagentRoundJSON.receipt(
        try await scheduler.receipt(rootID: rootID, childID: childID, requestID: requestID))
    case "round.ack":
      try await scheduler.acknowledge(
        rootID: rootID, childID: childID, requestID: Self.requiredString(payload, "requestID"),
        taskID: try Self.optionalString(payload, "taskID"))
      return .object([:])
    case "round.stopChild":
      try await scheduler.stopChild(
        rootID: rootID, childID: childID, expectedTaskID: Self.optionalString(payload, "taskID"),
        expectedRunID: Self.optionalString(payload, "runID"))
      return .object(["accepted": .bool(true)])
    default:
      let state = try await scheduler.cancelInput(
        rootID: rootID, childID: childID, requestID: Self.requiredString(payload, "requestID"))
      return .object(["state": .string(state.rawValue)])
    }
  }

  private func roundStart(
    _ payload: [String: ACPJSONValue], rootID: String, projectID: ProjectID,
    _ scheduler: SubagentRoundScheduler
  ) async throws -> ACPJSONValue {
    let childID = try Self.requiredString(payload, "childID")
    let requestID = try Self.requiredString(payload, "requestID")
    let request = SubagentStartRequest(
      rootID: rootID, childID: childID, requestID: requestID,
      parentSessionID: try Self.optionalString(payload, "parentSessionID") ?? rootID,
      projectID: projectID, installationID: try Self.requiredString(payload, "installationID"),
      prompt: try Self.requiredString(payload, "prompt"),
      options: SubagentRoundOptions(
        model: try Self.optionalString(payload, "model"),
        effort: try Self.optionalString(payload, "effort"),
        attachmentPaths: try Self.subagentAttachmentPaths(payload),
        label: try Self.optionalString(payload, "label"),
        origin: try Self.roundOrigin(payload)),
      access: try Self.requestedSubagentAccess(payload) == nil ? nil : .readOnly,
      dependsOn: try Self.stringList(payload, "dependsOn"))
    let result = try await scheduler.start(request)
    return .object([
      "childID": .string(childID), "requestID": .string(requestID), "state": .string("queued"),
      "created": .bool(result.created),
    ])
  }

  private func roundSend(
    _ payload: [String: ACPJSONValue], rootID: String, _ scheduler: SubagentRoundScheduler
  ) async throws -> ACPJSONValue {
    let childID = try Self.requiredString(payload, "childID")
    let request = SubagentSendRequest(
      childID: childID, requestID: try Self.requiredString(payload, "requestID"),
      prompt: try Self.requiredString(payload, "prompt"),
      delivery: try Self.roundDelivery(payload),
      attachmentPaths: try Self.subagentAttachmentPaths(payload),
      repairConflict: try Self.roundFlag(payload, "repairConflict"),
      expectedTaskID: try Self.optionalString(payload, "taskID"),
      expectedRunID: try Self.optionalString(payload, "runID"), createdAt: Date())
    return SubagentRoundJSON.send(
      try await scheduler.send(request, rootID: rootID), childID: childID)
  }

  // MARK: - Input

  /// The rounds the engine delivers itself, named as `[{childID, requestID}]`.
  static func awaitedRounds(_ payload: [String: ACPJSONValue], rootID: String) throws
    -> Set<SubagentRoundKey>
  {
    guard let value = payload["awaiting"], value != .null else { return [] }
    guard let items = value.arrayValue, items.count <= 256 else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.awaiting")
    }
    return Set(
      try items.map {
        SubagentRoundKey(
          rootID: rootID, childID: try requiredString($0.objectValue ?? [:], "childID"),
          requestID: try requiredString($0.objectValue ?? [:], "requestID"))
      })
  }

  private static func pinnedDependencies(_ payload: [String: ACPJSONValue]) throws
    -> [SubagentRoundDependency]?
  {
    guard let value = payload["dependencies"] else { return nil }
    guard let items = value.arrayValue, items.count <= 64 else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.dependencies")
    }
    return try items.map {
      try SubagentRoundDependency(
        childID: requiredString($0.objectValue ?? [:], "childID"),
        requestID: requiredString($0.objectValue ?? [:], "requestID"))
    }
  }

  static func optionalString(_ payload: [String: ACPJSONValue], _ key: String) throws -> String? {
    guard let value = payload[key], value != .null else { return nil }
    return try requiredString(payload, key)
  }

  static func stringList(_ payload: [String: ACPJSONValue], _ key: String) throws -> [String] {
    guard let value = payload[key], value != .null else { return [] }
    guard let items = value.arrayValue, items.count <= 64,
      items.allSatisfy({ $0.stringValue?.isEmpty == false })
    else { throw ServiceStoreError.invalidArgument("embedded_dsh.\(key)") }
    return items.compactMap(\.stringValue)
  }

  private static func roundDelivery(_ payload: [String: ACPJSONValue]) throws -> SubagentDelivery {
    guard let value = payload["delivery"], value != .null else { return .auto }
    guard let delivery = value.stringValue.flatMap(SubagentDelivery.init(rawValue:)) else {
      throw SubagentRoundRejection.unsupportedDelivery
    }
    return delivery
  }

  private static func roundOrigin(_ payload: [String: ACPJSONValue]) throws -> SubagentRoundOrigin {
    guard let value = payload["origin"], value != .null else { return .model }
    guard let origin = value.stringValue.flatMap(SubagentRoundOrigin.init(rawValue:)) else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.origin")
    }
    return origin
  }

  private static func roundFlag(_ payload: [String: ACPJSONValue], _ key: String) throws -> Bool {
    guard let value = payload[key], value != .null else { return false }
    guard let flag = value.boolValue else { throw SubagentRoundRejection.invalidOptions }
    return flag
  }
}

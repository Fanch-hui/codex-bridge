import BridgeACP
import BridgeEmbeddedDSH
import BridgeServiceCore
import Foundation

/// The production wiring of the scheduler's ports to the controller. Tasks, workspaces and events
/// are answered in process; the write lease and the root hold are two small engine actions that
/// never wait for another writer.
///
/// The controller owns the scheduler, which owns this object, so the link back is weak.
final class EmbeddedDSHSubagentPorts: @unchecked Sendable {
  private weak var controller: ServiceEmbeddedDSHController?

  init(controller: ServiceEmbeddedDSHController) {
    self.controller = controller
  }

  /// Runs `body` on the controller. Errors that may pass on their own are marked transient, so
  /// the scheduler keeps the round and tries again instead of failing it.
  private func guarded<T>(_ body: (ServiceEmbeddedDSHController) async throws -> T) async throws
    -> T
  {
    guard let controller else { throw CancellationError() }
    do {
      return try await body(controller)
    } catch {
      throw Self.classified(error)
    }
  }

  static func classified(_ error: any Error) -> any Error {
    if error is CancellationError || error is SubagentTransientError { return error }
    if let store = error as? ServiceStoreError, store == .storageBusy || store == .storageFailure {
      return SubagentTransientError(underlying: error)
    }
    let passes =
      error is WorkbenchAvailabilityError || error is EmbeddedDSHRuntimeError
      || error is EmbeddedDSHRecoveryError
    return passes ? SubagentTransientError(underlying: error) : error
  }

  private func engine(_ action: String, _ fields: [String: ACPJSONValue]) async throws
    -> ACPJSONValue
  {
    try await guarded { try await $0.invoke(action: action, payload: .object(fields)) }
  }
}

extension EmbeddedDSHSubagentPorts: SubagentTaskPort {
  func dispatchFirst(_ round: SubagentRound, prompt: String) async throws
    -> SubagentDispatchReceipt
  {
    try await guarded { try await $0.roundDispatchFirst(round, prompt: prompt) }
  }

  func dispatchContinuation(_ round: SubagentRound, prompt: String) async throws
    -> SubagentDispatchReceipt
  {
    try await guarded { try await $0.roundSend(round, prompt: prompt) }
  }

  func steer(_ round: SubagentRound, taskID: String, prompt: String) async throws
    -> SubagentDispatchReceipt
  {
    try await guarded { try await $0.roundSend(round, prompt: prompt, taskID: taskID) }
  }

  func snapshot(rootID: String, childID: String, taskID: String) async throws
    -> SubagentTaskSnapshot
  {
    try await guarded {
      try await $0.roundSnapshot(rootID: rootID, childID: childID, taskID: taskID)
    }
  }

  func view(rootID: String, childID: String, taskID: String) async throws -> SubagentTaskView {
    try await guarded { try await $0.roundView(rootID: rootID, childID: childID, taskID: taskID) }
  }

  func recoveredSnapshot(_ key: SubagentRoundKey) async throws -> SubagentTaskSnapshot {
    try await guarded { try await $0.roundRecoveredSnapshot(key) }
  }

  func probe(_ key: SubagentRoundKey) async throws -> SubagentProbe {
    try await guarded { try await $0.roundProbe(key) }
  }

  func stop(_ key: SubagentRoundKey, taskID: String?) async throws {
    try await guarded { try await $0.roundStop(key, taskID: taskID) }
  }

  func result(of key: SubagentRoundKey, taskID: String) async throws -> SubagentTaskResult {
    try await guarded { try await $0.roundResult(key, taskID: taskID) }
  }

  func isLegacyChild(rootID: String, childID: String) async throws -> Bool {
    try await guarded { try await $0.roundIsLegacyChild(rootID: rootID, childID: childID) }
  }
}

extension EmbeddedDSHSubagentPorts: SubagentWorkspacePort {
  func reserveExecution(_ round: SubagentRound) async throws -> Bool {
    try await guarded { try await $0.reserveRoundExecution(round) }
  }

  func rootIsReadOnly(rootID: String) async throws -> Bool {
    try await guarded { try await $0.roundRootIsReadOnly(rootID: rootID) }
  }

  func reserve(_ round: SubagentRound) async throws -> SubagentReservation {
    try await guarded { try await $0.roundReserve(round) }
  }

  func releaseReservation(_ key: SubagentRoundKey) async throws -> SubagentReservationRelease {
    try await guarded { try await $0.roundReleaseReservation(key) }
  }
}

extension EmbeddedDSHSubagentPorts: SubagentLeasePort {
  private func lease(_ operation: String, rootID: String, ownerID: String) async throws
    -> ACPJSONValue
  {
    try await guarded { controller in
      let project = try await controller.project(for: rootID)
      return try await controller.invoke(
        action: "subagent.lease",
        payload: .object([
          "operation": .string(operation), "rootSessionID": .string(rootID),
          "ownerID": .string(ownerID), "workspaceID": .string(project.id.rawValue),
        ]))
    }
  }

  func acquire(rootID: String, ownerID: String) async throws -> SubagentLeaseGrant {
    let value = try await lease("acquire", rootID: rootID, ownerID: ownerID)
    switch value["state"]?.stringValue {
    case "granted": return .granted
    case "waiting": return .waiting
    default: throw ServiceStoreError.invalidArgument("embedded_dsh.lease")
    }
  }

  func release(rootID: String, ownerID: String) async throws {
    _ = try await lease("release", rootID: rootID, ownerID: ownerID)
  }

  func recover(rootID: String, ownerID: String) async throws {
    _ = try await lease("recover", rootID: rootID, ownerID: ownerID)
  }
}

extension EmbeddedDSHSubagentPorts: SubagentRootPort {
  private func root(_ operation: String, rootID: String, holdID: String? = nil) async throws
    -> ACPJSONValue
  {
    var fields: [String: ACPJSONValue] = [
      "operation": .string(operation), "rootSessionID": .string(rootID),
    ]
    if let holdID { fields["holdID"] = .string(holdID) }
    return try await engine("subagent.root", fields)
  }

  func isStopped(rootID: String) async throws -> Bool {
    try await root("status", rootID: rootID)["stopped"]?.boolValue == true
  }

  func hold(rootID: String, holdID: String) async throws -> SubagentRootHold {
    let value = try await root("hold", rootID: rootID, holdID: holdID)
    return value["held"]?.boolValue == true ? .held : .stopped
  }

  func release(rootID: String, holdID: String) async throws {
    _ = try await root("release", rootID: rootID, holdID: holdID)
  }

  /// The engine answers at once and collects the results itself, so this never waits for a
  /// delivery; a notice it did not take is repeated by the next pass.
  func announceResults(rootID: String) async -> Bool {
    (try? await engine("subagent.deliveries", ["rootSessionID": .string(rootID)])) != nil
  }
}

extension EmbeddedDSHSubagentPorts: SubagentEventSink {
  func emit(sessionID: String, type: String, payload: ACPJSONValue) async {
    await controller?.receive(EmbeddedDSHEvent(sessionID: sessionID, type: type, payload: payload))
  }

  func report(rootID: String, message: String) async {
    await controller?.receive(
      EmbeddedDSHEvent(
        sessionID: rootID.isEmpty ? nil : rootID, type: "subagent.schedulerFailed",
        payload: .object(["message": .string(message)])))
  }
}

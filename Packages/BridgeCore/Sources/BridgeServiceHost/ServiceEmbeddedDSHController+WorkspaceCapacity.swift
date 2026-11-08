import BridgeACP
import BridgeDomain
import BridgeServiceCore
import Foundation

private struct WorkspaceReservation: Codable, Equatable, Sendable {
  let rootID: String
  let childID: String
  let requestID: String
}

extension ServiceEmbeddedDSHController {
  private static func workspaceReservationsKey(_ projectID: ProjectID) -> String {
    "embedded_dsh.workspace.reservations." + digest(projectID.rawValue)
  }

  func reserveSubagentWorkspace(
    rootID: String, childID: String, requestID: String, projectID: ProjectID,
    installationID: String? = nil
  ) async throws -> ACPJSONValue {
    // Resolved before taking the input gate so that waiting starts do not queue behind it.
    let writeScope = try await subagentWriteScope(installationID: installationID)
    let reserved: ACPJSONValue = .object([
      "state": .string("reserved"), "writeScope": .string(writeScope),
    ])
    await inputGate.acquire()
    defer { inputGate.release() }
    try Task.checkCancellation()
    guard let execution = try await application.embeddedDSHExecution(sessionID: rootID),
      execution.projectID == projectID, execution.rootActive, !execution.closing
    else { throw ServiceStoreError.invalidArgument("embedded_dsh.execution") }
    try await ensureSubagentRequestAdmitted(
      ["requestID": .string(requestID)], rootID: rootID, childID: childID)
    let reservation = WorkspaceReservation(rootID: rootID, childID: childID, requestID: requestID)
    var reservations = try await reconciledWorkspaceReservations(projectID: projectID)
    if reservations.contains(reservation) {
      try await saveWorkspaceReservations(reservations, projectID: projectID)
      return reserved
    }
    guard reservations.count < 2 else {
      try await saveWorkspaceReservations(reservations, projectID: projectID)
      return .object(["state": .string("waiting")])
    }
    reservations.append(reservation)
    try await saveWorkspaceReservations(reservations, projectID: projectID)
    return reserved
  }

  func releaseSubagentWorkspaceReservation(
    rootID: String, childID: String, requestID: String, projectID: ProjectID
  ) async throws -> ACPJSONValue {
    await inputGate.acquire()
    defer { inputGate.release() }
    let reservation = WorkspaceReservation(rootID: rootID, childID: childID, requestID: requestID)
    let input = try await store.embeddedDSHInput(
      parentSessionID: rootID, childID: childID, requestID: requestID)
    if input == nil,
      let child = try await application.embeddedDSHSubagent(
        parentSessionID: rootID, childID: childID),
      child.currentRequestID == requestID
    {
      return .object(["state": .string("unknown")])
    }
    let mode = try await workspaceMode(rootID: rootID, childID: childID)
    if let input, mode == "isolated" {
      guard let status = input.status, status != .unknown else {
        return .object(["state": .string("unknown")])
      }
      guard status.isTerminal else { return .object(["state": .string("active")]) }
    }
    var reservations = try await reconciledWorkspaceReservations(projectID: projectID)
    reservations.removeAll { $0 == reservation }
    let key = Self.workspaceReservationsKey(projectID)
    let encoded = try Self.encodeWorkspaceReservations(reservations)
    let revokedKey =
      "embedded_dsh.subagent.revoked."
      + Self.digest([rootID, childID, requestID].joined(separator: "\0"))
    let keys = input == nil ? [key, revokedKey] : [key]
    try await store.updateSettingsAtomically(keys: keys, updatedAt: Date()) { _ in
      var result = [key: encoded]
      if input == nil { result[revokedKey] = "revoked" }
      return result
    }
    return .object(["state": .string("released")])
  }

  private func reconciledWorkspaceReservations(projectID: ProjectID) async throws
    -> [WorkspaceReservation]
  {
    let key = Self.workspaceReservationsKey(projectID)
    let saved: [WorkspaceReservation]
    if let setting = try await store.setting(key: key) {
      saved = try JSONDecoder().decode([WorkspaceReservation].self, from: Data(setting.value.utf8))
    } else {
      saved = []
    }
    guard saved.count <= 256,
      Set(saved.map { [$0.rootID, $0.childID, $0.requestID] }).count == saved.count
    else { throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_reservations") }
    let executions = try await application.embeddedDSHExecutions().filter {
      $0.projectID == projectID
    }
    var active: [WorkspaceReservation] = []
    for reservation in saved {
      let input = try await store.embeddedDSHInput(
        parentSessionID: reservation.rootID, childID: reservation.childID,
        requestID: reservation.requestID)
      if let input {
        guard input.status?.isTerminal != true else { continue }
        guard
          try await workspaceMode(rootID: reservation.rootID, childID: reservation.childID)
            == "isolated"
        else { continue }
        active.append(reservation)
      } else if let child = try await application.embeddedDSHSubagent(
        parentSessionID: reservation.rootID, childID: reservation.childID),
        child.currentRequestID == reservation.requestID
      {
        active.append(reservation)
      } else if executions.contains(where: {
        $0.sessionID == reservation.rootID && $0.rootActive && !$0.closing
      }) {
        active.append(reservation)
      } else {
        let revokedKey =
          "embedded_dsh.subagent.revoked."
          + Self.digest(
            [reservation.rootID, reservation.childID, reservation.requestID]
              .joined(separator: "\0"))
        try await store.setSetting(
          ServiceSettingRecord(key: revokedKey, value: "revoked", updatedAt: Date()))
      }
    }
    for execution in executions {
      let children = try await application.embeddedDSHSubagents(
        parentSessionID: execution.sessionID)
      for child in children
      where child.currentTaskID != nil && child.currentStatus?.isTerminal != true {
        guard
          try await workspaceMode(rootID: execution.sessionID, childID: child.childID)
            == "isolated"
        else { continue }
        let reservation = WorkspaceReservation(
          rootID: execution.sessionID, childID: child.childID, requestID: child.currentRequestID)
        if !active.contains(reservation) { active.append(reservation) }
      }
    }
    return active
  }

  private func saveWorkspaceReservations(
    _ reservations: [WorkspaceReservation], projectID: ProjectID
  )
    async throws
  {
    let key = Self.workspaceReservationsKey(projectID)
    try await store.setSetting(
      ServiceSettingRecord(
        key: key, value: Self.encodeWorkspaceReservations(reservations), updatedAt: Date()))
  }

  private static func encodeWorkspaceReservations(_ reservations: [WorkspaceReservation]) throws
    -> String
  {
    guard let value = String(data: try JSONEncoder().encode(reservations), encoding: .utf8) else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_reservations")
    }
    return value
  }
}

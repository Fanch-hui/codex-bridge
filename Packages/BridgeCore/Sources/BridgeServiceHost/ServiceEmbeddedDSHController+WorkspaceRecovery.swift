import BridgeACP
import BridgeDomain
import BridgeFiles
import BridgeSecurity
import BridgeServiceApplication
import BridgeServiceCore
import Crypto
import Foundation

extension ServiceEmbeddedDSHController {
  public func restoreWorkspaceMergeRecoveryMarkers() async throws {
    let registered = try await projects.projects()
    for journal in try await workspaces.pendingMergeRecoveries() {
      guard
        let project = registered.first(where: {
          $0.root.identifies(
            canonicalPath: journal.projectRoot.canonicalPath,
            device: journal.projectRoot.identity.device, inode: journal.projectRoot.identity.inode)
        })
      else { continue }
      let existing = try await store.workspaceMergeRecoveries(projectID: project.id)
      guard !existing.contains(where: { $0.workspaceID == journal.id }) else { continue }
      let record = try await workspaceRecord(id: journal.id)
      try await store.setWorkspaceMergeRecovery(
        ServiceWorkspaceMergeRecovery(
          projectID: project.id, workspaceID: journal.id, rootID: record?.rootID ?? "",
          childID: record?.childID ?? "", taskID: record?.taskID ?? "",
          failureReason: journal.failureReason))
    }
  }

  func mergeWorkspaceRecoveryItems(projectID: ProjectID) async throws -> [ACPJSONValue] {
    var items: [ACPJSONValue] = []
    for marker in try await store.workspaceMergeRecoveries(projectID: projectID) {
      let journal: AgentWorkspaceMergeRecovery?
      let readFailure: String?
      do {
        journal = try await workspaces.mergeRecovery(id: marker.workspaceID)
        readFailure = nil
      } catch {
        journal = nil
        readFailure = OutboundContentSecurity.redactedSecrets(
          String(describing: error), maximumUTF8Bytes: 1_024)
      }
      let diverged = journal?.divergedPaths ?? []
      let inspectable = journal?.inspectionError == nil && readFailure == nil
      var item: [String: ACPJSONValue] = [
        "recoveryID": .string(marker.recoveryID), "kind": .string("merge"),
        "projectID": .string(projectID.rawValue),
        "status": .string("recovery_required"),
        "canResume": .bool(inspectable && diverged.isEmpty && journal?.isRollingBack != true),
        "canRollback": .bool(inspectable && diverged.isEmpty && journal != nil),
      ]
      if !marker.rootID.isEmpty { item["sessionId"] = .string(marker.rootID) }
      if let message = journal?.inspectionError ?? journal?.failureReason ?? marker.failureReason
        ?? readFailure
      {
        item["message"] = .string(message)
      }
      if !diverged.isEmpty { item["conflicts"] = .array(diverged.map(ACPJSONValue.string)) }
      items.append(.object(item))
    }
    for record in try await pendingWorkspaces(includeValidationRequired: true)
    where record.status == "validation_required"
      || (record.status == "pending" && record.candidatePath != nil)
    {
      guard
        let child = try await application.embeddedDSHSubagent(
          parentSessionID: record.rootID, childID: record.childID), child.projectID == projectID
      else { continue }
      let id = Self.workspaceValidationRecoveryID(record)
      var item: [String: ACPJSONValue] = [
        "recoveryID": .string(id), "kind": .string("merge"),
        "projectID": .string(projectID.rawValue), "sessionId": .string(record.rootID),
        "status": .string(record.status == "pending" ? "validating" : "validation_required"),
        "canConfigureValidation": .bool(record.status == "validation_required"),
        "canResume": .bool(record.status == "validation_required"),
      ]
      if let message = record.failureReason { item["message"] = .string(message) }
      if let path = record.candidatePath { item["candidatePath"] = .string(path) }
      items.append(.object(item))
    }
    return items
  }

  func recoverWorkspaceMerge(recoveryID: String, projectID: ProjectID, rollback: Bool)
    async throws -> ACPJSONValue
  {
    let markers = try await store.workspaceMergeRecoveries(projectID: projectID)
    guard let marker = markers.first(where: { $0.recoveryID == recoveryID }) else {
      guard !rollback else {
        throw ServiceStoreError.invalidArgument("workspace.recovery_missing")
      }
      return try await resumeWorkspaceValidation(recoveryID: recoveryID, projectID: projectID)
    }
    let owner = "recovery:" + recoveryID + ":" + UUID().uuidString
    let token: String?
    if marker.rootID.isEmpty {
      token = nil
    } else if let acquired = try await acquireMergeLease(rootID: marker.rootID, owner: owner) {
      token = acquired
    } else {
      throw ProjectWorkspaceBusyError.busy(.direct(owner: "workspace_recovery"))
    }
    let projectLease: DirectWorkspaceLease
    do {
      projectLease = try await application.acquireEmbeddedDSHWorkspaceMergeLease(
        sessionID: marker.rootID, projectID: projectID, operationID: owner,
        permittingRecoveryID: marker.workspaceID)
    } catch {
      if let token {
        try await releaseMergeLease(rootID: marker.rootID, owner: owner, token: token)
      }
      throw error
    }
    do {
      let current = try await store.workspaceMergeRecoveries(projectID: projectID)
      guard
        current.contains(where: {
          $0.workspaceID == marker.workspaceID && $0.recoveryID == recoveryID
        })
      else { throw ServiceStoreError.invalidArgument("workspace.recovery_missing") }
    } catch {
      await projectLease.release()
      if let token {
        try await releaseMergeLease(rootID: marker.rootID, owner: owner, token: token)
      }
      throw error
    }
    let result: ACPJSONValue
    do {
      result = try await finishWorkspaceRecovery(marker, rollback: rollback)
    } catch {
      var failed = marker
      failed.failureReason = OutboundContentSecurity.redactedSecrets(
        String(describing: error), maximumUTF8Bytes: 1_024)
      do { try await store.setWorkspaceMergeRecovery(failed) } catch {
        await projectLease.release()
        if let token {
          try await releaseMergeLease(rootID: marker.rootID, owner: owner, token: token)
        }
        throw error
      }
      await projectLease.release()
      if let token {
        try await releaseMergeLease(rootID: marker.rootID, owner: owner, token: token)
      }
      throw error
    }
    await projectLease.release()
    if let token {
      try await releaseMergeLease(rootID: marker.rootID, owner: owner, token: token)
    }
    return result
  }

  private func finishWorkspaceRecovery(_ marker: ServiceWorkspaceMergeRecovery, rollback: Bool)
    async throws -> ACPJSONValue
  {
    var record = try await workspaceRecord(id: marker.workspaceID)
    let journal = try await workspaces.mergeRecovery(id: marker.workspaceID)
    let status: String
    if rollback {
      guard journal != nil, try await workspaces.rollbackMerge(id: marker.workspaceID) else {
        throw ServiceStoreError.invalidArgument("workspace.rollback_unavailable")
      }
      status = "retained"
    } else if let journal {
      guard !journal.isRollingBack else {
        throw ServiceStoreError.invalidArgument("workspace.rollback_required")
      }
      guard let result = try await workspaces.recoverMerge(id: marker.workspaceID) else {
        throw AgentWorkspaceError.workspaceUnavailable
      }
      status = "merged"
      record?.setPaths(changedFiles: result.changedPaths, conflicts: [])
    } else {
      status = "pending"
    }
    if var record {
      record.status = status
      record.failureReason = nil
      try await persistWorkspaceRecord(record)
    }
    try await store.clearWorkspaceMergeRecovery(
      projectID: marker.projectID, workspaceID: marker.workspaceID, recoveryID: marker.recoveryID)
    await application.workspaceMergeRecoveryChanged()
    if status == "pending", !marker.rootID.isEmpty, !marker.childID.isEmpty {
      scheduleWorkspaceMerge(rootID: marker.rootID, childID: marker.childID)
    }
    return .object(["accepted": .bool(true), "status": .string(status)])
  }

  private func resumeWorkspaceValidation(recoveryID: String, projectID: ProjectID)
    async throws -> ACPJSONValue
  {
    for record in try await pendingWorkspaces(includeValidationRequired: true)
    where record.status == "validation_required" {
      let id = Self.workspaceValidationRecoveryID(record)
      guard id == recoveryID,
        let child = try await application.embeddedDSHSubagent(
          parentSessionID: record.rootID, childID: record.childID), child.projectID == projectID
      else { continue }
      let workspace = Self.workspaceID(rootID: record.rootID, childID: record.childID)
      await inputGate.acquire()
      do {
        guard var current = try await workspaceRecord(id: workspace),
          current.status == "validation_required",
          Self.workspaceValidationRecoveryID(current) == recoveryID,
          child.currentTaskID?.rawValue == current.taskID
        else {
          inputGate.release()
          continue
        }
        current.status = "pending"
        current.failureReason = nil
        try await persistWorkspaceRecordLocked(current)
        inputGate.release()
      } catch {
        inputGate.release()
        throw error
      }
      scheduleWorkspaceMerge(rootID: record.rootID, childID: record.childID)
      return .object(["accepted": .bool(true), "status": .string("pending")])
    }
    throw ServiceStoreError.invalidArgument("workspace.recovery_missing")
  }

  private static func workspaceValidationRecoveryID(_ record: WorkbenchWorkspaceRecord) -> String {
    let workspace = workspaceID(rootID: record.rootID, childID: record.childID)
    let input = workspace + "\0" + record.taskID + "\0" + (record.candidateID ?? "")
    let digest = SHA256.hash(data: Data(input.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return "validation:" + digest
  }
}

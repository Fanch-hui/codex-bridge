import BridgeDomain
import BridgeFiles
import BridgeProcess
import BridgeSecurity
import BridgeServiceApplication
import BridgeServiceCore
import Foundation

private enum ValidatedWorkspaceOutcome: Equatable {
  case completed, stale, busy
}

extension ServiceEmbeddedDSHController {
  func discardRecordedCandidate(_ record: inout WorkbenchWorkspaceRecord, workspaceID: String)
    async throws
  {
    guard let candidateID = record.candidateID else { return }
    try await workspaces.discardMergeCandidate(workspaceID: workspaceID, candidateID: candidateID)
    record.candidateID = nil
    record.candidatePath = nil
    try await persistWorkspaceRecord(record)
  }

  func applyWorkspaceResolutions(_ record: inout WorkbenchWorkspaceRecord, workspaceID: String)
    async throws
  {
    if let recovered = try await workspaces.recoverConflictResolution(id: workspaceID),
      let requestID = record.resolutionRequestID, recovered.archiveID != requestID
    {
      throw AgentWorkspaceError.recoveryRequired(recovered.resolvedPaths)
    }
    guard let resolutions = record.resolutions, let requestID = record.resolutionRequestID else {
      return
    }
    let result = try await workspaces.resolveConflicts(
      id: workspaceID,
      resolutions: resolutions.map {
        AgentWorkspaceConflictResolution(
          relativePath: $0.relativePath, expectedSHA256: $0.expectedSHA256)
      }, requestID: requestID)
    record.resolvedInputs = resolutions
    record.resolutions = nil
    record.resolutionRequestID = nil
    record.resolutionArchiveID = result.archiveID
    try await persistWorkspaceRecord(record)
  }

  func prepareAndMergeWorkspace(
    _ record: inout WorkbenchWorkspaceRecord, child: EmbeddedDSHSubagentBinding,
    scope: ManagedProcessOwnershipScope
  ) async throws {
    let id = Self.workspaceID(rootID: record.rootID, childID: record.childID)
    for attempt in 0..<3 {
      try Task.checkCancellation()
      do {
        let plan = try await workspaces.planMerge(id: id)
        record.setPaths(changedFiles: plan.changedPaths, conflicts: plan.conflicts)
        if !plan.conflicts.isEmpty {
          record.status = "conflict"
          try await persistWorkspaceRecord(record)
          return
        }
        if plan.changedPaths.isEmpty {
          record.status = "merged"
          record.failureReason = nil
          try await persistWorkspaceRecord(record)
          return
        }
        let configuration = try await workspaceValidationConfiguration(projectID: child.projectID)
        let candidateID = UUID().uuidString.lowercased()
        record.candidateID = candidateID
        record.candidatePath = nil
        try await persistWorkspaceRecord(record)
        let candidate = try await workspaces.prepareMergeCandidate(
          plan: plan, candidateID: candidateID)
        record.candidatePath = candidate.root.canonicalPath
        try await persistWorkspaceRecord(record)
        guard !configuration.commands.isEmpty else {
          record.status = "validation_required"
          record.failureReason = "配置验证命令后即可继续合并。"
          try await persistWorkspaceRecord(record)
          return
        }
        do {
          try await validateWorkspaceCandidate(
            candidate, projectID: child.projectID, configuration: configuration, scope: scope)
        } catch {
          record.status = "validation_required"
          record.failureReason = workspaceMergeFailureReason(error)
          try await persistWorkspaceRecord(record)
          return
        }
        let outcome = try await applyValidatedWorkspaceCandidate(
          &record, child: child, plan: plan, candidate: candidate, configuration: configuration)
        if outcome == .completed {
          if record.status == "merged" {
            try await discardRecordedCandidate(&record, workspaceID: id)
          }
          return
        }
        try await discardRecordedCandidate(&record, workspaceID: id)
        if outcome == .busy { return }
      } catch AgentWorkspaceError.revisionConflict where attempt < 2 {
        try await discardRecordedCandidate(&record, workspaceID: id)
      }
    }
    record.status = "validation_required"
    record.failureReason = "项目在验证期间发生变化，请重新验证。"
    try await persistWorkspaceRecord(record)
  }

  private func applyValidatedWorkspaceCandidate(
    _ record: inout WorkbenchWorkspaceRecord, child: EmbeddedDSHSubagentBinding,
    plan: AgentWorkspaceMergePlan, candidate: AgentWorkspaceMergeCandidate,
    configuration: WorkbenchValidationConfiguration
  ) async throws -> ValidatedWorkspaceOutcome {
    let owner = "merge:" + plan.id + ":" + UUID().uuidString
    guard let token = try await acquireMergeLease(rootID: record.rootID, owner: owner) else {
      return .busy
    }
    let lease: DirectWorkspaceLease
    do {
      lease = try await application.acquireEmbeddedDSHWorkspaceMergeLease(
        sessionID: record.rootID, projectID: child.projectID, operationID: owner)
    } catch {
      try await releaseMergeLease(rootID: record.rootID, owner: owner, token: token)
      if case ProjectWorkspaceBusyError.busy = error { return .busy }
      throw error
    }
    let result: ValidatedWorkspaceOutcome
    do {
      if try await workspaceValidationConfiguration(projectID: child.projectID) != configuration {
        result = .stale
      } else {
        result = try await commitValidatedWorkspaceCandidate(
          &record, child: child, plan: plan, candidate: candidate)
      }
    } catch {
      await lease.release()
      try await releaseMergeLease(rootID: record.rootID, owner: owner, token: token)
      throw error
    }
    await lease.release()
    try await releaseMergeLease(rootID: record.rootID, owner: owner, token: token)
    return result
  }

  private func commitValidatedWorkspaceCandidate(
    _ record: inout WorkbenchWorkspaceRecord, child: EmbeddedDSHSubagentBinding,
    plan: AgentWorkspaceMergePlan, candidate: AgentWorkspaceMergeCandidate
  ) async throws -> ValidatedWorkspaceOutcome {
    var marker = ServiceWorkspaceMergeRecovery(
      projectID: child.projectID, workspaceID: plan.id, rootID: record.rootID,
      childID: record.childID, taskID: record.taskID)
    try await store.setWorkspaceMergeRecovery(marker)
    do {
      let applied = try await workspaces.applyMerge(plan: plan, verifiedCandidate: candidate)
      record.status = "merged"
      record.failureReason = nil
      record.setPaths(changedFiles: applied.changedPaths, conflicts: [])
      try await persistWorkspaceRecord(record)
      try await store.clearWorkspaceMergeRecovery(
        projectID: child.projectID, workspaceID: plan.id, recoveryID: marker.recoveryID)
      await application.workspaceMergeRecoveryChanged()
      return .completed
    } catch AgentWorkspaceError.revisionConflict {
      guard try await workspaces.mergeRecovery(id: plan.id) == nil else {
        throw AgentWorkspaceError.recoveryRequired(plan.changedPaths)
      }
      try await store.clearWorkspaceMergeRecovery(
        projectID: child.projectID, workspaceID: plan.id, recoveryID: marker.recoveryID)
      await application.workspaceMergeRecoveryChanged()
      return .stale
    } catch {
      marker.failureReason = workspaceMergeFailureReason(error)
      record.status = "recovery_required"
      record.failureReason = marker.failureReason
      try await store.setWorkspaceMergeRecovery(marker)
      try await persistWorkspaceRecord(record)
      return .completed
    }
  }

  private func workspaceMergeFailureReason(_ error: any Error) -> String {
    let description =
      (error as? AgentWorkspaceRecoveryFailure)?.failureReason
      ?? String(describing: error)
    return OutboundContentSecurity.redactedSecrets(description, maximumUTF8Bytes: 1_024)
  }
}

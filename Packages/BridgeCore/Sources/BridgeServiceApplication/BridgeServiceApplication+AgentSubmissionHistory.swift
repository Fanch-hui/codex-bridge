import BridgeAgentCore
import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  func agentContinuationSource(
    submission: MCPServiceTaskSubmission, policy: ServiceAgentProviderPolicy,
    registry: ServiceAgentRegistry, providerID: AgentProviderID,
    record: ServiceAgentInstallationRecord, project: ServiceProjectRecord
  ) async throws -> ServiceTaskRecord? {
    guard policy.supportsSessionContinuation, let requestedSessionID = submission.threadID else {
      return nil
    }
    let previous = try await tasks.task(
      providerSessionID: requestedSessionID, providerID: providerID.rawValue,
      installationID: record.id.rawValue, projectID: project.id)
    if let previous {
      guard previous.state.status.isTerminal else { throw BridgeMCPQueryError.invalidTaskState }
      return previous
    }
    guard providerID == .pi || providerID == .qoder || providerID == .deepSeekHarnessDesktop else {
      throw BridgeMCPQueryError.taskNotFound
    }
    let (directory, installation, verifiedRecord) =
      try await registry
      .nativeSessionDirectoryManager(installationID: record.id)
    let scope = try await nativeSessionScope(project: project, installation: verifiedRecord)
    let active = try await tasks.nonterminalTasks().contains { task in
      task.projectID == project.id && task.providerID == providerID.rawValue
        && task.installationID == record.id.rawValue
        && (task.state.providerSessionID ?? task.requestedThreadID) == requestedSessionID
    }
    guard !active,
      try await directory.isIndexedNativeSession(
        sessionID: requestedSessionID, scope: scope, installation: installation)
    else { throw BridgeMCPQueryError.taskNotFound }
    return nil
  }

  func agentAttachmentSource(
    submission: MCPServiceTaskSubmission, source: ServiceTaskSource,
    providerID: AgentProviderID, record: ServiceAgentInstallationRecord,
    project: ServiceProjectRecord
  ) async throws -> ServiceTaskRecord? {
    guard let sourceTaskID = submission.attachmentSourceTaskID else { return nil }
    guard source == .macOSApp, submission.threadID == nil, sourceTaskID.utf8.count <= 128,
      let sourceTask = try await tasks.task(id: TaskID(rawValue: sourceTaskID)),
      sourceTask.state.status.isTerminal, sourceTask.projectID == project.id,
      sourceTask.providerID == providerID.rawValue,
      sourceTask.installationID == record.id.rawValue
    else { throw BridgeMCPQueryError.contractRejected }
    return sourceTask
  }

  func agentSubmissionAttachments(
    submission: MCPServiceTaskSubmission, sourceTaskRecord: ServiceTaskRecord?,
    providerID: AgentProviderID, record: ServiceAgentInstallationRecord,
    project: ServiceProjectRecord, model: AgentModelDescriptor?
  ) async throws -> [AgentImageAttachment] {
    guard let sourceTask = sourceTaskRecord else {
      return try ServiceAgentAttachments.capture(
        relativePaths: submission.attachmentPaths ?? [], project: project, model: model)
    }
    let originalAttachments = try await tasks.taskAttachments(taskID: sourceTask.id)
    guard let confirmedSourceTask = try await tasks.task(id: sourceTask.id),
      confirmedSourceTask.state.status.isTerminal,
      confirmedSourceTask.projectID == project.id,
      confirmedSourceTask.providerID == providerID.rawValue,
      confirmedSourceTask.installationID == record.id.rawValue
    else { throw BridgeMCPQueryError.contractRejected }
    return try ServiceAgentAttachments.captureForRestart(
      relativePaths: submission.attachmentPaths ?? [], originalAttachments: originalAttachments,
      project: project, model: model)
  }
}

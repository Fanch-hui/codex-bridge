import BridgeAgentCore
import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  func prepareTaskSubmission(
    _ submission: MCPServiceTaskSubmission,
    sourceClientID: String,
    source: ServiceTaskSource,
    deadline: ContinuousClock.Instant
  ) async throws -> PreparedTaskSubmission {
    let projectID = try await submissionProjectID(explicit: submission.projectID)
    let project = try await readableProject(projectID)
    let workbenchPermissionMode = try await workbenchDefaultPermissionMode(
      sourceClientID: sourceClientID
    )
    if let providerRaw = submission.providerID, providerRaw != serviceCodexProviderID {
      return try await prepareAgentSubmission(
        submission,
        providerRaw: providerRaw,
        project: project,
        sourceClientID: sourceClientID,
        source: source,
        workbenchPermissionMode: workbenchPermissionMode,
        deadline: deadline
      )
    }
    guard submission.attachmentPaths?.isEmpty != false,
      submission.attachmentSourceTaskID == nil
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    let models: [MCPModelSummary]?
    do {
      models = try await catalog.listModels(deadline: deadline).models
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try Self.checkDeadline(deadline)
      models = nil
    }
    let selections = try await modelSelections(submission: submission, models: models)
    let requestedPermissionMode = try Self.permissionModeRequest(
      submission.permissionMode,
      override: submission.permissionModeOverride,
      requirePermissionModeOverride: workbenchPermissionMode != nil
    )
    let permission = try Self.permissionMode(
      requestedPermissionMode,
      project: project,
      defaultMode: workbenchPermissionMode
    )
    let accessMode = try await settings.accessMode()
    let fastMode =
      try await settings.isFastModeEnabled()
      && models?.first(where: { $0.modelID == selections.execution.model })?
        .supportsFastMode == true
    guard !submission.networkAccess || project.accessPolicy.network != .denied else {
      throw BridgeMCPQueryError.contractRejected
    }
    let selectedSkills = try await selectedSkillSnapshots(
      for: submission,
      project: project,
      deadline: deadline
    )
    let taskPrompt = try await taskPrompt(
      for: submission,
      deadline: deadline,
      selectedSkills: selectedSkills
    )
    return PreparedTaskSubmission(
      projectID: project.id,
      request: ServiceTaskRequest(
        projectID: project.id,
        source: source,
        sourceClientID: source == .mcpClient ? sourceClientID : "",
        clientRequestID: submission.clientRequestID,
        prompt: taskPrompt,
        requestedThreadID: submission.threadID,
        executionModel: selections.execution.model,
        executionEffort: selections.execution.effort,
        supervisorModel: selections.supervisor?.model,
        supervisorEffort: selections.supervisor?.effort,
        permissionMode: permission,
        networkAllowed: submission.networkAccess,
        accessMode: accessMode,
        fastMode: fastMode,
        queueIfBusy: submission.queueIfBusy == true,
        selectedSkills: selectedSkills
      )
    )
  }

  private func workbenchDefaultPermissionMode(
    sourceClientID: String
  ) async throws -> ServicePermissionMode? {
    guard
      sourceClientID == MCPClientID.chatGPT.rawValue
        || sourceClientID == MCPClientID.qwenStudio.rawValue
    else {
      return nil
    }
    return try await settings.workbenchPermissionMode()
  }

  private func submissionProjectID(explicit: String?) async throws -> String {
    if let explicit { return explicit }
    guard let projectID = try await defaultSubmissionProjectID(in: projects.projects()) else {
      throw BridgeMCPQueryError.projectNotFound
    }
    return projectID
  }

  func taskPrompt(
    for submission: MCPServiceTaskSubmission,
    deadline: ContinuousClock.Instant,
    selectedSkills: [AgentSelectedSkill]
  ) async throws -> String {
    var prompt = Self.prompt(
      submission.prompt,
      acceptanceCriteria: submission.acceptanceCriteria
    )
    if submission.providerID != "pi", submission.providerID != "qoder" {
      let names = (submission.skillNames ?? []) + [submission.skillName].compactMap { $0 }
      var seen = Set<String>()
      for skillName in names where seen.insert(skillName).inserted {
        try Self.checkDeadline(deadline)
        let skill = try await serviceReadSkill(
          skillName: skillName, projectID: submission.projectID, subpath: "SKILL.md",
          deadline: deadline)
        let instructions = String(skill.content.prefix(8 * 1_024))
        prompt = "Skill instructions for \(skill.name):\n\n\(instructions)\n\nUser task:\n\(prompt)"
      }
    }
    guard prompt.utf8.count <= 32 * 1_024 else {
      throw BridgeMCPQueryError.contractRejected
    }
    return prompt
  }
}

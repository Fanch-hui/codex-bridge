import BridgeACP
import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

typealias SubagentSubmitter =
  @Sendable (MCPServiceTaskSubmission, String, String, ContinuousClock.Instant) async throws ->
  MCPServiceTaskSubmissionReceipt

struct SubagentStartPreparation: Sendable {
  let providerID: String
  let installationID: String?
  let model: String?
  let effort: String?
}

/// Serializes the unlocked preparation of one child, so two requests for the same copy never race
/// each other without holding the controller-wide `inputGate` for the whole preparation.
final class SubagentLanes: @unchecked Sendable {
  final class Lane: @unchecked Sendable {
    let key: String
    let mutex = AsyncMutex()
    fileprivate var users = 0
    fileprivate init(key: String) { self.key = key }
  }

  private let lock = NSLock()
  private var lanes: [String: Lane] = [:]

  func acquire(_ key: String) async -> Lane {
    let lane = register(key)
    await lane.mutex.acquire()
    return lane
  }

  func release(_ lane: Lane) {
    lane.mutex.release()
    lock.lock()
    defer { lock.unlock() }
    lane.users -= 1
    if lane.users == 0 { lanes[lane.key] = nil }
  }

  /// Requests holding or waiting for the lane of this key.
  func userCount(_ key: String) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return lanes[key]?.users ?? 0
  }

  private func register(_ key: String) -> Lane {
    lock.lock()
    defer { lock.unlock() }
    let lane = lanes[key] ?? Lane(key: key)
    lanes[key] = lane
    lane.users += 1
    return lane
  }
}

extension ServiceEmbeddedDSHController {
  /// Read-only preparation (provider and model checks) runs before any lock so that parallel
  /// starts only queue for the short submission step.
  func prepareSubagentStart(_ payload: [String: ACPJSONValue], projectID: ProjectID) async
    -> Result<SubagentStartPreparation, any Error>
  {
    do {
      let installationID = try Self.requiredString(payload, "installationID")
      let providerID = try await subagentProviderID(installationID: installationID)
      let submissionInstallationID = installationID == "codex" ? nil : installationID
      let (model, effort) = try await resolveSubagentModelOverrides(
        payload, projectID: projectID, providerID: providerID,
        installationID: submissionInstallationID, nativeSessionID: nil,
        deadline: .now.advanced(by: .seconds(40)))
      return .success(
        SubagentStartPreparation(
          providerID: providerID, installationID: submissionInstallationID,
          model: model, effort: effort))
    } catch {
      return .failure(error)
    }
  }

  /// Starts a child in three steps. Copying the project (and probing the provider inside the copy)
  /// takes seconds on a large project, so it runs outside `inputGate`; the gate is taken again only
  /// to recheck what may have changed meanwhile and to submit.
  ///
  /// - The child lane keeps two starts of the same child from preparing one copy at once. A
  ///   duplicate request waits, then finds the original submission and replays its receipt.
  /// - A copy that was prepared but never activated is discarded on every failure path.
  func startSubagent(
    _ payload: [String: ACPJSONValue], rootID: String, childID: String, projectID: ProjectID,
    preparation: Result<SubagentStartPreparation, any Error>
  ) async throws -> ACPJSONValue {
    let lane = await subagentLanes.acquire(Self.workspaceID(rootID: rootID, childID: childID))
    defer { subagentLanes.release(lane) }
    try Task.checkCancellation()
    if let replay = try await previousSubagentSubmission(
      payload, rootID: rootID, childID: childID)
    {
      return replay
    }
    try await ensureSubagentRequestAdmitted(payload, rootID: rootID, childID: childID)
    let start = try preparation.get()
    let plan = try await stageSubagentWorkspace(
      payload, rootID: rootID, childID: childID, projectID: projectID,
      providerID: start.providerID, installationID: start.installationID)
    return try await submitStagedSubagent(
      payload, rootID: rootID, childID: childID, projectID: projectID, start: start, plan: plan)
  }

  /// Everything slow, without `inputGate`. The result is only a plan: the gated step rechecks the
  /// session, the request and any merge recovery before it activates a prepared copy.
  private func stageSubagentWorkspace(
    _ payload: [String: ACPJSONValue], rootID: String, childID: String, projectID: ProjectID,
    providerID: String, installationID: String?
  ) async throws -> SubagentWorkspacePlan {
    let execution = try await activeSubagentExecution(rootID: rootID)
    let permission = try await subagentPermission(
      payload, execution: execution, rootID: rootID, childID: childID, continuation: false)
    try await requireNoWorkspaceMergeRecovery(permissionMode: permission, projectID: projectID)
    let id = Self.workspaceID(rootID: rootID, childID: childID)
    guard try await store.setting(key: Self.workspaceModeKey(id)) == nil else { return .existing }
    return try await planNewSubagentWorkspace(
      id: id, projectID: projectID, providerID: providerID, installationID: installationID,
      permissionMode: permission, continuation: false)
  }

  private func submitStagedSubagent(
    _ payload: [String: ACPJSONValue], rootID: String, childID: String, projectID: ProjectID,
    start: SubagentStartPreparation, plan: SubagentWorkspacePlan
  ) async throws -> ACPJSONValue {
    await inputGate.acquire()
    defer { inputGate.release() }
    do {
      try Task.checkCancellation()
      if let replay = try await previousSubagentSubmission(
        payload, rootID: rootID, childID: childID)
      {
        await discardUnstartedWorkspace(plan)
        return replay
      }
      try await ensureSubagentRequestAdmitted(payload, rootID: rootID, childID: childID)
      return try await submitSubagent(
        payload, rootID: rootID, childID: childID, projectID: projectID,
        providerID: start.providerID, installationID: start.installationID,
        nativeSessionID: nil, modelOverrides: (start.model, start.effort), workspacePlan: plan)
    } catch {
      // Nothing is left behind for a request that never ran: an activated copy is kept by the
      // store, an untouched one goes.
      await discardUnstartedWorkspace(plan)
      throw error
    }
  }

  /// Records the request, settles the workspace and submits the task. Runs under `inputGate`.
  /// A `workspacePlan` comes from `startSubagent`; without one the workspace is settled inline,
  /// which is all a continuation needs.
  func submitSubagent(
    _ payload: [String: ACPJSONValue], rootID: String, childID: String, projectID: ProjectID,
    providerID: String, installationID: String?, nativeSessionID: String?,
    originalFingerprint: String? = nil, modelOverrides: (model: String?, effort: String?)? = nil,
    workspacePlan: SubagentWorkspacePlan? = nil
  ) async throws -> ACPJSONValue {
    let requestID = try Self.requiredString(payload, "requestID")
    let prompt = try Self.requiredString(payload, "prompt")
    let attachmentPaths = try Self.subagentAttachmentPaths(payload)
    let fingerprint = try originalFingerprint ?? Self.subagentSubmissionFingerprint(payload)
    try await recordSubagentSubmission(
      fingerprint: fingerprint, requestID: requestID, rootID: rootID, childID: childID)
    let execution = try await activeSubagentExecution(rootID: rootID)
    let continuation = nativeSessionID != nil
    let permission = try await subagentPermission(
      payload, execution: execution, rootID: rootID, childID: childID,
      continuation: continuation)
    let deadline = ContinuousClock.now.advanced(by: .seconds(40))
    let (requestedModel, requestedEffort) =
      if let modelOverrides {
        modelOverrides
      } else {
        try await resolveSubagentModelOverrides(
          payload, projectID: projectID, providerID: providerID, installationID: installationID,
          nativeSessionID: nativeSessionID, deadline: deadline)
      }
    let workspace = try await resolveSubagentWorkspace(
      workspacePlan, rootID: rootID, childID: childID, projectID: projectID,
      providerID: providerID, installationID: installationID,
      permissionMode: permission, continuation: continuation)
    if !continuation {
      try await recordSubagentAccess(permission, rootID: rootID, childID: childID)
    }
    let submission = MCPServiceTaskSubmission(
      projectID: projectID.rawValue,
      prompt: try Self.subagentTaskPrompt(prompt, workspace: workspace),
      threadID: nativeSessionID, providerID: providerID, installationID: installationID,
      executionModel: requestedModel, executionEffort: requestedEffort,
      modelOverride: requestedModel != nil || requestedEffort != nil,
      permissionMode: permission.rawValue, clientRequestID: requestID,
      queueIfBusy: false, attachmentPaths: attachmentPaths)
    let result = try await submitReadOnlyAware(
      submission, rootID: rootID, childID: childID, deadline: deadline)
    return try await subagentReceipt(result, workspace: workspace, rootID: rootID, childID: childID)
  }

  private func subagentReceipt(
    _ result: MCPServiceTaskSubmissionReceipt, workspace: SubagentWorkspaceOutcome,
    rootID: String, childID: String
  ) async throws -> ACPJSONValue {
    var receipt: [String: ACPJSONValue] = [
      "childID": .string(childID), "taskID": .string(result.taskID),
      "state": .string(result.status), "waitingForApproval": .bool(result.localApprovalRequired),
      "workspaceMode": .string(workspace.mode),
    ]
    if let reason = try await workspaceReason(rootID: rootID, childID: childID) {
      receipt["workspaceReason"] = .string(reason)
    }
    return .object(receipt)
  }

  private func resolveSubagentWorkspace(
    _ plan: SubagentWorkspacePlan?, rootID: String, childID: String, projectID: ProjectID,
    providerID: String, installationID: String?, permissionMode: ServicePermissionMode,
    continuation: Bool
  ) async throws -> SubagentWorkspaceOutcome {
    guard let plan else {
      return try await prepareSubagentWorkspace(
        rootID: rootID, childID: childID, projectID: projectID, providerID: providerID,
        installationID: installationID, permissionMode: permissionMode,
        continuation: continuation)
    }
    // Merge recovery may have started while the copy was being made.
    try await requireNoWorkspaceMergeRecovery(
      permissionMode: permissionMode, projectID: projectID)
    return try await commitSubagentWorkspace(
      plan, rootID: rootID, childID: childID, projectID: projectID, providerID: providerID,
      continuation: continuation)
  }

  private static func subagentTaskPrompt(_ prompt: String, workspace: SubagentWorkspaceOutcome)
    throws -> String
  {
    var taskPrompt = prompt
    if workspace.mode == "isolated" {
      taskPrompt +=
        "\n\nThis task runs in an isolated copy with controlled file tools. "
        + "Shell commands, child processes, and external MCP tools are unavailable. "
        + "Edit the files directly; the merge validation runs project checks and tests."
    }
    if !workspace.synchronizedPaths.isEmpty {
      let paths = try json(.array(workspace.synchronizedPaths.map(ACPJSONValue.string)))
      taskPrompt +=
        "\n\nThe isolated workspace was synchronized with the project. Changed paths include: "
        + paths
    }
    if !workspace.repairPaths.isEmpty {
      let paths = try json(.array(workspace.repairPaths.map(ACPJSONValue.string)))
      taskPrompt +=
        "\n\nResolve and remove every BRIDGE_CONFLICT marker in the workspace. Affected paths include: "
        + paths + ". An empty conflict version means the file was deleted."
    }
    return taskPrompt
  }

  /// The execution of the root session, which must still accept new children.
  func activeSubagentExecution(rootID: String) async throws -> EmbeddedDSHExecution {
    guard let execution = try await application.embeddedDSHExecution(sessionID: rootID) else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.execution")
    }
    guard execution.rootActive, !execution.closing else {
      throw ServiceStoreError.invalidArgument("dsh.executionOwner")
    }
    return execution
  }

  func dispatchSubagentSubmission(
    _ submission: MCPServiceTaskSubmission, rootID: String, childID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskSubmissionReceipt {
    if let subagentSubmitter {
      return try await subagentSubmitter(submission, rootID, childID, deadline)
    }
    return try await application.submitEmbeddedDSHSubagent(
      submission, parentSessionID: rootID, childID: childID, deadline: deadline)
  }

  func setSubagentSubmitter(_ submitter: SubagentSubmitter?) {
    subagentSubmitter = submitter
  }
}

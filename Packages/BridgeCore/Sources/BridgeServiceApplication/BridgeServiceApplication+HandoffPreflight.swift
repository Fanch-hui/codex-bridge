import BridgeAgentCore
import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  struct HandoffPreflight {
    let prepared: PreparedTaskSubmission
    let fingerprint: String
    let contextWindowTokens: Int?
  }

  func handoffPreflight(
    source: ServiceTaskRecord, providerID: String, handoffID: String,
    prompt: String, deadline: ContinuousClock.Instant
  ) async throws -> HandoffPreflight {
    guard source.state.status.isTerminal, providerID != source.providerID,
      ServiceAgentProviderPolicyRegistry.policy(for: providerID) != nil
    else { throw TaskHandoffError.rejected("来源任务尚未结束或目标 Agent 不受支持。") }
    let project = try await readableProject(source.projectID.rawValue)
    let submission = MCPServiceTaskSubmission(
      projectID: source.projectID.rawValue, prompt: prompt, providerID: providerID,
      permissionMode: source.permissionMode.rawValue, permissionModeOverride: true,
      networkAccess: source.networkAllowed, clientRequestID: "handoff:" + handoffID)
    let prepared = try await prepareTaskSubmission(
      submission, sourceClientID: "macos.app", source: .macOSApp, deadline: deadline)
    var capabilityFingerprint = "codex"
    var contextWindowTokens: Int?
    if providerID == serviceCodexProviderID {
      let models = try await catalog.listModels(deadline: deadline).models
      guard models.contains(where: { $0.modelID == prepared.request.executionModel }) else {
        throw TaskHandoffError.rejected("Codex 当前未提供所选模型，请先连接并刷新模型列表。")
      }
    } else {
      guard let installationID = prepared.request.installationID else {
        throw TaskHandoffError.rejected("目标 Agent 没有可用安装。")
      }
      let installation = try await requiredAgentRegistry().validateForExecution(
        installationID: AgentInstallationID(rawValue: installationID))
      let capabilities = installation.capabilities.effective
      let mutationIntent: AgentMutationIntent =
        prepared.request.permissionMode == .workspaceWrite ? .workspaceWrite : .readOnly
      guard installation.isSelectable, capabilities.contains(.sessionCreate),
        capabilities.contains(.workspaceRead),
        mutationIntent == .workspaceWrite
          || capabilities.isSuperset(
            of: mutationIntent.requiredCapabilities(for: installation.providerID))
      else {
        throw TaskHandoffError.rejected("目标 Agent 无法创建会话或不支持所选读写模式。")
      }
      if prepared.request.permissionMode == .workspaceWrite {
        guard
          capabilities.contains(.workspaceWriteInPlace)
            || capabilities.contains(.workspaceWriteIsolated)
        else {
          throw TaskHandoffError.rejected("目标 Agent 未提供所需的工作区写入能力。")
        }
      }
      if capabilities.contains(.modelSelection),
        prepared.request.executionModel != serviceDefaultProviderExecutionModel
      {
        let models = try await serviceAgentModelCatalog(
          registry: requiredAgentRegistry(), installationID: installation.id,
          projectRoot: project.root.canonicalPath, selectedModelID: prepared.request.executionModel)
        guard let model = models.first(where: { $0.id == prepared.request.executionModel }) else {
          throw TaskHandoffError.rejected("目标 Agent 当前未提供所选模型，请刷新模型配置。")
        }
        contextWindowTokens = model.contextWindowTokens
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let region =
        installation.providerID == .qoder
        ? try await qoderDistribution(for: installation)?.rawValue : nil
      capabilityFingerprint =
        capabilities.map(\.rawValue).sorted().joined(separator: ",")
        + "|" + (installation.version ?? "") + "|" + (installation.protocolRevision ?? "")
        + "|" + installation.executableIdentity.sha256
        + "|" + (region ?? "")
        + "|" + (try encoder.encode(installation.artifacts)).base64EncodedString()
    }
    let value = prepared.request
    let fingerprint = Self.handoffDigest([
      source.projectID.rawValue, project.root.canonicalPath,
      String(project.updatedAt.timeIntervalSince1970), providerID, value.installationID ?? "",
      value.executionModel, value.executionEffort, value.permissionMode.rawValue,
      String(value.networkAllowed), value.accessMode.rawValue, String(value.fastMode),
      value.supervisorModel ?? "", value.supervisorEffort ?? "", capabilityFingerprint,
      contextWindowTokens.map(String.init) ?? "",
    ])
    return HandoffPreflight(
      prepared: prepared, fingerprint: fingerprint, contextWindowTokens: contextWindowTokens)
  }

  func handoffStatus(_ record: ServiceTaskHandoffRecord) async throws -> MCPTaskHandoffPreview {
    let original = record.preview
    var phase = handoffOperations.contains(original.handoffID) ? "submitting" : "prepared"
    var message: String? = nil
    if let targetID = record.targetTaskID {
      if let task = try await tasks.task(id: TaskID(rawValue: targetID)) {
        phase = task.state.status.rawValue
        switch task.state.status {
        case .completed:
          message = "接手任务已结束；任务验收仍需核对实际结果和测试。"
        case .failed, .interrupted, .unknown:
          message = "接手任务状态：\(phase)。\(task.state.failureCode ?? "请查看任务详情；不会自动重跑。")"
        case .awaitingLocalApproval:
          message = "任务已持久化，尚未启动；确认同一交接可继续启动，不会新建任务。"
        case .starting:
          message = "正在启动目标 Agent；尚未确认交接正文已被接收。"
        default:
          message = "目标执行通道已建立；尚不能证明内容理解或任务验收成功。"
        }
        if task.state.status == .running,
          try await tasks.handoffAcknowledged(taskID: task.id, handoffID: original.handoffID)
        {
          phase = "acknowledged"
          message = "已收到 Agent 的交接回执；这不是对理解准确性或验收结果的保证。"
        }
      } else {
        phase = "target_deleted"
        message = "接手任务已被删除；同一交接 ID 不会重新执行。"
      }
    }
    return MCPTaskHandoffPreview(
      handoffID: original.handoffID, sourceTaskID: original.sourceTaskID,
      providerID: original.providerID, model: original.model,
      permissionMode: original.permissionMode, networkAllowed: original.networkAllowed,
      revision: original.revision, prompt: original.prompt,
      additionalInstructions: original.additionalInstructions, warnings: original.warnings,
      ready: original.ready && (phase == "prepared" || phase == "awaiting_local_approval"),
      estimatedTokens: original.estimatedTokens, contextWindowTokens: original.contextWindowTokens,
      phase: phase, targetTaskID: record.targetTaskID, message: message)
  }
}

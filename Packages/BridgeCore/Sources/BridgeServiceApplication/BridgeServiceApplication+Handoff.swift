import BridgeDomain
import BridgeMCP
import BridgeSecurity
import BridgeServiceCore
import Crypto
import Foundation

extension BridgeServiceApplication {
  public func serviceTaskHandoff(
    _ request: MCPTaskHandoffRequest, deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskHandoffPreview {
    try Self.checkDeadline(deadline)
    guard !request.handoffID.isEmpty, request.handoffID.utf8.count <= 128,
      request.handoffID.unicodeScalars.allSatisfy({
        CharacterSet(
          charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
        ).contains($0)
      }),
      request.additionalInstructions.utf8.count <= TaskHandoffRenderer.maximumAdditionalBytes,
      !request.additionalInstructions.contains("\0")
    else { throw TaskHandoffError.rejected("交接 ID 或补充内容不合法。") }
    let existing = try await tasks.handoff(id: request.handoffID)
    if let existing {
      _ = try await readableProject(existing.packet.projectID)
      guard existing.packet.sourceTaskID == request.sourceTaskID,
        existing.preview.providerID == request.providerID
      else { throw TaskHandoffError.rejected("交接与来源任务或目标 Agent 不匹配。") }
      if request.action == .status { return try await handoffStatus(existing) }
      if request.action == .prepare {
        let clean = OutboundContentSecurity.redactedSecrets(
          request.additionalInstructions, maximumUTF8Bytes: 8192)
        guard existing.preview.additionalInstructions == clean else {
          throw TaskHandoffError.rejected("同一交接 ID 的补充内容已改变，请先查询原交接。")
        }
        return try await handoffStatus(existing)
      }
      return try await submitHandoff(
        existing, expectedRevision: request.expectedRevision, deadline: deadline)
    }
    guard request.action == .prepare else {
      throw TaskHandoffError.rejected("交接记录不存在，请重新准备；未执行任何目标任务。")
    }
    guard handoffOperations.insert(request.handoffID).inserted else {
      throw TaskHandoffError.rejected("正在准备同一交接，请查询该交接状态。")
    }
    defer { handoffOperations.remove(request.handoffID) }
    let sourceID = TaskID(rawValue: request.sourceTaskID)
    guard let source = try await tasks.task(id: sourceID) else {
      throw BridgeMCPQueryError.taskNotFound
    }
    _ = try await readableProject(source.projectID.rawValue)
    let packet = try await tasks.handoffPacket(taskID: sourceID)
    let target = try await handoffPreflight(
      source: source, providerID: request.providerID, handoffID: request.handoffID,
      prompt: "交接预检（不会启动 Agent）", deadline: deadline)
    let additional = OutboundContentSecurity.redactedSecrets(
      request.additionalInstructions, maximumUTF8Bytes: 8192)
    let rendered = TaskHandoffRenderer.render(
      packet, handoffID: request.handoffID, additionalInstructions: additional)
    let revision = Self.handoffDigest([
      packet.sourceRevision, rendered.prompt, additional, target.fingerprint,
    ])
    let preview = MCPTaskHandoffPreview(
      handoffID: request.handoffID, sourceTaskID: request.sourceTaskID,
      providerID: request.providerID, model: target.prepared.request.executionModel,
      permissionMode: target.prepared.request.permissionMode.rawValue,
      networkAllowed: target.prepared.request.networkAllowed,
      revision: revision, prompt: rendered.prompt, additionalInstructions: additional,
      warnings: rendered.warnings, ready: rendered.ready, estimatedTokens: rendered.estimatedTokens)
    try Self.checkDeadline(deadline)
    try await tasks.saveHandoff(
      .init(packet: packet, preview: preview, targetFingerprint: target.fingerprint))
    return preview
  }

  private func submitHandoff(
    _ record: ServiceTaskHandoffRecord, expectedRevision: String?, deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskHandoffPreview {
    let id = record.preview.handoffID
    guard expectedRevision == record.preview.revision, record.preview.ready else {
      throw TaskHandoffError.rejected("请先生成并确认当前版本的交接预览。")
    }
    guard handoffOperations.insert(id).inserted else { return try await handoffStatus(record) }
    defer { handoffOperations.remove(id) }
    if let targetID = record.targetTaskID {
      if let target = try await tasks.task(id: TaskID(rawValue: targetID)),
        target.state.status == .awaitingLocalApproval, !target.isQueued
      {
        guard let source = try await tasks.task(id: TaskID(rawValue: record.packet.sourceTaskID))
        else {
          throw TaskHandoffError.rejected("来源任务已删除，不能自动恢复未启动交接。")
        }
        let current = try await tasks.handoffPacket(taskID: source.id)
        let preflight = try await handoffPreflight(
          source: source, providerID: record.preview.providerID, handoffID: id,
          prompt: record.preview.prompt, deadline: deadline)
        guard current.sourceRevision == record.packet.sourceRevision,
          preflight.fingerprint == record.targetFingerprint
        else { throw TaskHandoffError.rejected("来源或目标配置已改变，未启动的交接需要重新确认。") }
        try await approveAndStartTask(
          target.id, summary: "The local App confirmed the persisted handoff.")
      }
      return try await handoffStatus(record)
    }
    guard let source = try await tasks.task(id: TaskID(rawValue: record.packet.sourceTaskID)) else {
      throw BridgeMCPQueryError.taskNotFound
    }
    let current = try await tasks.handoffPacket(taskID: source.id)
    guard current.sourceRevision == record.packet.sourceRevision else {
      throw TaskHandoffError.rejected("来源记录已改变，请重新准备交接；旧预览不会发送。")
    }
    let target = try await handoffPreflight(
      source: source, providerID: record.preview.providerID, handoffID: id,
      prompt: record.preview.prompt, deadline: deadline)
    guard target.fingerprint == record.targetFingerprint else {
      throw TaskHandoffError.rejected("目标模型、安装、权限或项目配置已改变，请重新准备交接。")
    }
    try Self.checkDeadline(deadline)
    let admission = try await workspaceGate.beginTaskAdmission()
    do {
      let created = try await submitTaskWithAdmission(
        target.prepared.request, projectID: target.prepared.projectID, handoffID: id)
      if created.task.state.status == .awaitingLocalApproval, !created.task.isQueued {
        try await approveAndStartTask(
          created.task.id, summary: "The local App confirmed the persisted handoff.")
      }
      await workspaceGate.endTaskAdmission(token: admission)
    } catch {
      await workspaceGate.endTaskAdmission(token: admission)
      if let persisted = try await tasks.handoff(id: id), persisted.targetTaskID != nil {
        return try await handoffStatus(persisted)
      }
      throw error
    }
    guard let persisted = try await tasks.handoff(id: id) else {
      throw TaskHandoffError.rejected("交接回执暂不可读取，请查询同一交接 ID，勿重复创建。")
    }
    return try await handoffStatus(persisted)
  }

  static func handoffDigest(_ parts: [String]) -> String {
    var hash = SHA256()
    for part in parts {
      hash.update(data: Data("\(part.utf8.count):".utf8))
      hash.update(data: Data(part.utf8))
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

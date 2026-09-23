import BridgeDomain
import BridgeSecurity
import Crypto
import Foundation
import GRDB

extension SimpleServiceStore {
  public func handoffPacket(taskID: TaskID) throws -> TaskHandoffPacket {
    try database.read { db in try Self.handoffPacket(taskID: taskID, in: db) }
  }

  static func handoffPacket(taskID: TaskID, in db: Database) throws -> TaskHandoffPacket {
    guard let row = try Self.taskRow(id: taskID, in: db) else {
      throw ServiceStoreError.unknownTask(taskID)
    }
    let source = try Self.decodeTask(row)
    let sessionID =
      source.providerID == serviceCodexProviderID
      ? source.state.codexThreadID ?? source.requestedThreadID ?? source.id.rawValue
      : source.state.providerSessionID ?? source.requestedThreadID ?? source.id.rawValue
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT * FROM bridge_service_tasks
        WHERE project_id = ? AND provider_id = ? AND installation_id IS ?
          AND COALESCE(CASE WHEN provider_id = 'codex' THEN codex_thread_id
            ELSE provider_session_id END, requested_thread_id, task_id) = ?
        ORDER BY created_at ASC, task_id ASC LIMIT 257
        """,
      arguments: [source.projectID.rawValue, source.providerID, source.installationID, sessionID])
    let turns = try rows.map(Self.decodeTask)
    guard turns.count <= 256, turns.last?.id == source.id,
      turns.allSatisfy({ $0.state.status.isTerminal })
    else {
      throw TaskHandoffError.rejected("请从已结束会话的最新一轮交接；会话过长或仍有活跃任务时不会生成不完整摘要。")
    }
    var builder = HandoffSourceBuilder()
    for turn in turns {
      let ancestor = try Self.handoff(targetTaskID: turn.id.rawValue, in: db)
      try builder.append(turn, ancestor: ancestor, in: db)
    }
    if let first = turns.first, first.requestedThreadID != nil,
      try Self.handoff(targetTaskID: first.id.rawValue, in: db) == nil
    {
      builder.historyComplete = false
      builder.warnings.append("Bridge 记录从原生会话中途开始，无法证明已收齐此前用户要求。")
    }
    return builder.packet(source: source)
  }
}

private struct HandoffSourceBuilder {
  var requirements: [TaskHandoffItem] = []
  var outcomes: [TaskHandoffItem] = []
  var evidence: [TaskHandoffItem] = []
  var files = Set<String>()
  var warnings: [String] = []
  var historyComplete = true
  private var seen = Set<String>()
  private var revision = SHA256()
  private var usedBytes = 0

  mutating func append(
    _ turn: ServiceTaskRecord, ancestor: ServiceTaskHandoffRecord?, in db: Database
  ) throws {
    let id = turn.id.rawValue
    if turn.state.failureCode == "conversation_persistence_failed" {
      historyComplete = false
      warnings.append("来源会话发生过消息持久化失败，无法确认用户要求完整。")
    }
    hash([
      id, String(turn.createdAt.timeIntervalSince1970),
      String(turn.updatedAt.timeIntervalSince1970),
      turn.state.status.rawValue, turn.state.failureCode ?? "", turn.prompt,
    ])
    if let ancestor {
      guard ancestor.packet.projectID == turn.projectID.rawValue,
        ancestor.preview.prompt == turn.prompt
      else { throw TaskHandoffError.rejected("历史交接链的项目或内容校验失败。") }
      hash([ancestor.packet.sourceRevision, ancestor.preview.revision])
      historyComplete = historyComplete && ancestor.packet.historyComplete
      warnings.append(contentsOf: ancestor.packet.warnings)
      for item in ancestor.packet.requirements { try add(item, to: .requirement) }
      for item in ancestor.packet.outcomes { try add(item, to: .outcome) }
      for item in ancestor.packet.evidence { try add(item, to: .evidence) }
      files.formUnion(ancestor.packet.changedFiles)
      if !ancestor.preview.additionalInstructions.isEmpty {
        try add(
          .init(
            id: "handoff-addition:" + ancestor.preview.handoffID,
            sourceTaskID: id, kind: "user", text: ancestor.preview.additionalInstructions),
          to: .requirement)
      }
    } else {
      if turn.clientRequestID?.hasPrefix("handoff:") == true
        || (turn.clientRequestID?.hasPrefix("handoff-") == true
          && turn.prompt.hasPrefix("接手以下项目任务，先核对当前工作区"))
      {
        historyComplete = false
        warnings.append("交接链的原始结构化记录缺失。")
      }
      try add(
        .init(id: "prompt:" + id, sourceTaskID: id, kind: "user", text: clean(turn.prompt)),
        to: .requirement)
    }
    let total =
      try Int.fetchOne(
        db,
        sql: """
          SELECT COALESCE(SUM(length(CAST(content AS BLOB))), 0)
          FROM bridge_service_task_messages WHERE task_id = ? AND role = 'user'
          """, arguments: [id]) ?? 0
    guard total <= 512 * 1024 else {
      throw TaskHandoffError.rejected("用户要求记录超过安全读取上限；已停止而非截取部分要求。")
    }
    let messages = try Row.fetchAll(
      db,
      sql: """
        SELECT message_id, content, updated_at FROM bridge_service_task_messages
        WHERE task_id = ? AND role = 'user' ORDER BY message_id ASC LIMIT 513
        """, arguments: [id])
    guard messages.count <= 512 else {
      throw TaskHandoffError.rejected("运行中追加要求过多，已停止而非静默丢弃。")
    }
    var skippedInitial = false
    for message in messages {
      let messageID: Int64 = message["message_id"]
      let content: String = message["content"]
      let updatedAt: Double = message["updated_at"]
      hash([String(messageID), String(updatedAt), content])
      if !skippedInitial, content == turn.prompt {
        skippedInitial = true
        continue
      }
      try add(
        .init(
          id: "message:\(messageID)", sourceTaskID: id, kind: "user-steer", text: clean(content)),
        to: .requirement)
    }
    let status = "状态：\(turn.state.status.rawValue)；失败代码：\(turn.state.failureCode ?? "无记录")"
    try add(
      .init(id: "status:" + id, sourceTaskID: id, kind: "recorded-state", text: status),
      to: .outcome)
    if let result = turn.state.resultSummary {
      hash([result])
      try add(
        .init(
          id: "result:" + id, sourceTaskID: id, kind: "agent-claim-unverified", text: clean(result)),
        to: .evidence)
    }
    if let step = turn.state.currentStep {
      hash([step])
      try add(
        .init(id: "step:" + id, sourceTaskID: id, kind: "last-step-unverified", text: clean(step)),
        to: .evidence)
    }
    let commands = try Row.fetchAll(
      db,
      sql: """
        SELECT event_id, summary FROM bridge_service_task_events
        WHERE task_id = ? AND kind = 'execution.command_completed'
        ORDER BY event_id DESC LIMIT 33
        """, arguments: [id])
    if commands.count > 32 { warnings.append("部分任务的命令证据仅保留最近 32 项，不是完整命令历史。") }
    for command in commands.prefix(32).reversed() {
      let eventID: Int64 = command["event_id"]
      let summary: String = command["summary"]
      hash([String(eventID), summary])
      try add(
        .init(
          id: "command:\(eventID)", sourceTaskID: id,
          kind: "recorded-command-not-current-verification", text: clean(summary)), to: .evidence)
    }
    let safePaths = turn.state.changedFiles.filter {
      OutboundContentSecurity.isSafeOutboundRelativePath($0, maximumUTF8Bytes: 2048)
    }
    if safePaths.count != turn.state.changedFiles.count {
      warnings.append("过长或非安全相对路径未写入文件清单；接手时请重新核对工作区。")
    }
    files.formUnion(safePaths)
    hash(turn.state.changedFiles)
  }

  func packet(source: ServiceTaskRecord) -> TaskHandoffPacket {
    var finalWarnings = Array(Set(warnings)).sorted()
    finalWarnings.append("记录中的凭据已脱敏；未复制原 Agent 的私有会话、工具权限或隐藏推理。")
    finalWarnings.append("仅覆盖 Bridge 仍保留的任务与消息；主动删除的历史和未同步的原生会话内容不在交接范围。")
    finalWarnings.append("工作区可能在预览后改变，接手 Agent 必须重新读取文件并核对，不得把历史文件列表当作实时 diff。")
    return TaskHandoffPacket(
      projectID: source.projectID.rawValue, sourceTaskID: source.id.rawValue,
      sourceProviderID: source.providerID,
      sourceRevision: revision.finalize().map { String(format: "%02x", $0) }.joined(),
      capturedAt: ISO8601DateFormatter().string(from: source.updatedAt),
      requirements: requirements, outcomes: outcomes, evidence: evidence,
      changedFiles: files.sorted(), warnings: finalWarnings, historyComplete: historyComplete)
  }

  private enum Category: Equatable { case requirement, outcome, evidence }

  private mutating func add(_ item: TaskHandoffItem, to category: Category) throws {
    guard seen.insert(item.id).inserted else { return }
    let item = boundedEvidence(item, category: category)
    let count = item.text.utf8.count
    if category == .evidence {
      while usedBytes + count > 512 * 1024,
        let index = evidence.firstIndex(where: {
          $0.sourceTaskID != item.sourceTaskID
            || ($0.kind != "agent-claim-unverified" && $0.kind != "last-step-unverified")
        })
      {
        usedBytes -= evidence.remove(at: index).text.utf8.count
        warnings.append("较早的非用户要求证据已被更新证据替换；完整性受历史预算限制。")
      }
    }
    if category == .evidence, usedBytes + count > 512 * 1024 {
      guard item.kind != "agent-claim-unverified" && item.kind != "last-step-unverified" else {
        throw TaskHandoffError.rejected("无法在预算内保留最新结果与用户要求，已停止交接。")
      }
      warnings.append("非用户要求的历史证据超过存储预算，已省略；不能视为完整验证记录。")
      return
    }
    guard usedBytes + count <= 768 * 1024 else {
      throw TaskHandoffError.rejected("关键交接数据过大，已停止；未丢弃用户要求。")
    }
    usedBytes += count
    switch category {
    case .requirement: requirements.append(item)
    case .outcome: outcomes.append(item)
    case .evidence: evidence.append(item)
    }
  }

  private mutating func hash(_ strings: [String]) {
    for string in strings {
      revision.update(data: Data("\(string.utf8.count):".utf8))
      revision.update(data: Data(string.utf8))
    }
  }

  private mutating func boundedEvidence(_ item: TaskHandoffItem, category: Category)
    -> TaskHandoffItem
  {
    guard category == .evidence, item.text.utf8.count > 16 * 1024 else { return item }
    warnings.append("过长的 Agent 结果或命令证据保留首尾，中段已节选；不能视为完整验证记录。")
    return TaskHandoffItem(
      id: item.id, sourceTaskID: item.sourceTaskID, kind: item.kind,
      text: TaskHandoffRenderer.headAndTail(item.text, maximumBytes: 16 * 1024))
  }

  private func clean(_ text: String) -> String {
    OutboundContentSecurity.redactedSecrets(
      text, maximumUTF8Bytes: max(1, text.utf8.count + 64 * 1024)
    )
    .replacingOccurrences(of: "\0", with: "[NUL]")
  }
}

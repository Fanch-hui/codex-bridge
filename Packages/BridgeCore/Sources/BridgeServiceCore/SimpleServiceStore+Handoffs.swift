import BridgeDomain
import Foundation
import GRDB

public struct ServiceTaskHandoffRecord: Equatable, Sendable {
  public let packet: TaskHandoffPacket
  public let preview: TaskHandoffPreview
  public let targetFingerprint: String
  public let targetTaskID: String?

  public init(
    packet: TaskHandoffPacket, preview: TaskHandoffPreview,
    targetFingerprint: String, targetTaskID: String? = nil
  ) {
    self.packet = packet
    self.preview = preview
    self.targetFingerprint = targetFingerprint
    self.targetTaskID = targetTaskID
  }
}

extension SimpleServiceStore {
  public func saveHandoff(_ record: ServiceTaskHandoffRecord) throws {
    let id = record.preview.handoffID
    try ServiceValidation.identifier(id, field: "handoff.id", maximumBytes: 128)
    let packet = try JSONEncoder().encode(record.packet)
    let preview = try JSONEncoder().encode(record.preview)
    guard packet.count <= 1024 * 1024, preview.count <= 192 * 1024,
      record.packet.schemaVersion == TaskHandoffPacket.currentSchemaVersion
    else { throw TaskHandoffError.rejected("交接记录过大或版本不受支持。") }
    try database.write { db in
      if let existing = try Self.handoff(id: id, in: db) {
        guard existing.packet == record.packet, existing.preview == record.preview,
          existing.targetFingerprint == record.targetFingerprint
        else { throw TaskHandoffError.rejected("同一交接 ID 的内容冲突；请查询原交接，不能覆盖。") }
        return
      }
      try db.execute(
        sql: """
          INSERT INTO bridge_service_handoffs
            (handoff_id, project_id, source_task_id, target_fingerprint, packet_json, preview_json, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          id, record.packet.projectID, record.packet.sourceTaskID, record.targetFingerprint,
          packet, preview, Date().timeIntervalSince1970,
        ])
    }
  }

  public func handoff(id: String) throws -> ServiceTaskHandoffRecord? {
    try ServiceValidation.identifier(id, field: "handoff.id", maximumBytes: 128)
    return try database.read { db in try Self.handoff(id: id, in: db) }
  }

  static func handoff(id: String, in db: Database) throws -> ServiceTaskHandoffRecord? {
    try Row.fetchOne(
      db, sql: "SELECT * FROM bridge_service_handoffs WHERE handoff_id = ?", arguments: [id]
    )
    .map(decodeHandoff)
  }

  static func handoff(targetTaskID: String, in db: Database) throws -> ServiceTaskHandoffRecord? {
    try Row.fetchOne(
      db, sql: "SELECT * FROM bridge_service_handoffs WHERE target_task_id = ?",
      arguments: [targetTaskID]
    )
    .map(decodeHandoff)
  }

  static func decodeHandoff(_ row: Row) throws -> ServiceTaskHandoffRecord {
    let packetData: Data = row["packet_json"]
    let previewData: Data = row["preview_json"]
    let packet = try JSONDecoder().decode(TaskHandoffPacket.self, from: packetData)
    let preview = try JSONDecoder().decode(TaskHandoffPreview.self, from: previewData)
    guard packet.schemaVersion == TaskHandoffPacket.currentSchemaVersion,
      packet.projectID == row["project_id"] as String,
      packet.sourceTaskID == row["source_task_id"] as String,
      preview.handoffID == row["handoff_id"] as String
    else { throw TaskHandoffError.rejected("交接记录版本或绑定校验失败。") }
    return ServiceTaskHandoffRecord(
      packet: packet, preview: preview, targetFingerprint: row["target_fingerprint"],
      targetTaskID: row["target_task_id"])
  }

  static func validateHandoffSubmission(
    _ id: String, task: ServiceTaskRecord, in db: Database
  ) throws {
    guard let record = try handoff(id: id, in: db), record.preview.ready,
      task.source == .macOSApp, task.sourceClientID.isEmpty,
      task.clientRequestID == "handoff:" + id,
      task.projectID.rawValue == record.packet.projectID,
      task.providerID == record.preview.providerID,
      task.executionModel == record.preview.model,
      task.prompt == record.preview.prompt, task.requestedThreadID == nil,
      task.permissionMode.rawValue == record.preview.permissionMode,
      task.networkAllowed == record.preview.networkAllowed
    else { throw TaskHandoffError.rejected("交接内容或目标绑定不匹配，已阻止发送。") }
    if record.targetTaskID == nil {
      let current = try handoffPacket(taskID: TaskID(rawValue: record.packet.sourceTaskID), in: db)
      guard current.sourceRevision == record.packet.sourceRevision else {
        throw TaskHandoffError.rejected("来源在提交期间发生变化；旧交接未执行，请重新准备。")
      }
    }
    if let targetID = record.targetTaskID,
      try taskRow(id: TaskID(rawValue: targetID), in: db) == nil
    {
      // A deleted target is a tombstone, never permission to execute again.
      throw TaskHandoffError.rejected("接手任务已被删除；同一交接不会重新执行。")
    }
  }

  static func linkHandoff(_ id: String, taskID: String, in db: Database) throws {
    try db.execute(
      sql: """
        UPDATE bridge_service_handoffs SET target_task_id = ?
        WHERE handoff_id = ? AND (target_task_id IS NULL OR target_task_id = ?)
        """, arguments: [taskID, id, taskID])
    guard db.changesCount == 1 else {
      throw TaskHandoffError.rejected("交接已绑定其他任务，不能重复执行。")
    }
  }
}

extension ServiceTaskManager {
  public func saveHandoff(_ record: ServiceTaskHandoffRecord) async throws {
    try await store.saveHandoff(record)
  }

  public func handoff(id: String) async throws -> ServiceTaskHandoffRecord? {
    try await store.handoff(id: id)
  }

  public func handoffPacket(taskID: TaskID) async throws -> TaskHandoffPacket {
    try await store.handoffPacket(taskID: taskID)
  }
}

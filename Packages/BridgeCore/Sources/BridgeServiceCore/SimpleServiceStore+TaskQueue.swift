import BridgeDomain
import Foundation
import GRDB

public struct ServiceTaskQueueInfo: Equatable, Sendable {
  public let position: Int
  public let occupyingTaskID: TaskID?
  public let enqueuedAt: Date

  public init(position: Int, occupyingTaskID: TaskID?, enqueuedAt: Date) {
    self.position = position
    self.occupyingTaskID = occupyingTaskID
    self.enqueuedAt = enqueuedAt
  }
}

extension SimpleServiceStore {
  public func queuedTasks(projectID: ProjectID? = nil, limit: Int = 500)
    throws -> [ServiceTaskRecord]
  {
    guard (1...500).contains(limit) else {
      throw ServiceStoreError.invalidArgument("taskQueue.limit")
    }
    do {
      return try database.read { db in
        let rows: [Row]
        if let projectID {
          rows = try Row.fetchAll(
            db,
            sql: """
              SELECT t.* FROM bridge_service_task_queue q
              JOIN bridge_service_tasks t ON t.task_id = q.task_id
              WHERE t.project_id = ?
              ORDER BY q.enqueued_at, q.task_id
              LIMIT ?
              """,
            arguments: [projectID.rawValue, limit]
          )
        } else {
          rows = try Row.fetchAll(
            db,
            sql: """
              SELECT t.* FROM bridge_service_task_queue q
              JOIN bridge_service_tasks t ON t.task_id = q.task_id
              ORDER BY q.enqueued_at, q.task_id
              LIMIT ?
              """,
            arguments: [limit]
          )
        }
        return try rows.map(Self.decodeTask)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func taskQueueInfo(id: TaskID) throws -> ServiceTaskQueueInfo? {
    do {
      return try database.read { db in
        guard
          let row = try Row.fetchOne(
            db,
            sql: """
              SELECT t.project_id, q.enqueued_at
              FROM bridge_service_task_queue q
              JOIN bridge_service_tasks t ON t.task_id = q.task_id
              WHERE q.task_id = ?
              """,
            arguments: [id.rawValue]
          )
        else { return nil }
        let position =
          (try Int.fetchOne(
            db,
            sql: """
              SELECT COUNT(*) FROM bridge_service_task_queue q
              JOIN bridge_service_tasks t ON t.task_id = q.task_id
              WHERE t.project_id = ?
                AND (q.enqueued_at < ? OR (q.enqueued_at = ? AND q.task_id <= ?))
              """,
            arguments: [
              row["project_id"] as String,
              row["enqueued_at"] as Double,
              row["enqueued_at"] as Double,
              id.rawValue,
            ]
          ) ?? 0)
        let occupant = try Self.activeWriteTaskRow(
          projectID: ProjectID(rawValue: row["project_id"]), in: db
        ).map { try Self.decodeTask($0).id }
        return ServiceTaskQueueInfo(
          position: position,
          occupyingTaskID: occupant,
          enqueuedAt: Date(timeIntervalSince1970: row["enqueued_at"])
        )
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  func promoteQueuedTask(
    id: TaskID,
    at date: Date,
    event: ServiceTaskEventDraft
  ) throws -> ServiceTaskRecord? {
    guard event.kind == .executionStarting, event.createdAt == date else {
      throw ServiceStoreError.invalidArgument("taskQueue.promotionEvent")
    }
    do {
      return try database.write { db in
        guard let row = try Self.taskRow(id: id, in: db) else {
          throw ServiceStoreError.unknownTask(id)
        }
        let existing = try Self.decodeTask(row)
        guard existing.isQueued else { return nil }
        guard
          try
            (existing.permissionMode != .workspaceWrite
            || Self.activeWriteTaskRow(projectID: existing.projectID, in: db) == nil)
        else { return nil }
        guard try Self.projectRow(id: existing.projectID, in: db) != nil else {
          throw ServiceStoreError.unknownProject(existing.projectID)
        }
        let promoted = try existing.replacingQueueState(false, updatedAt: date)
        try updateTaskRow(promoted, in: db)
        try db.execute(
          sql: "DELETE FROM bridge_service_task_queue WHERE task_id = ?",
          arguments: [id.rawValue]
        )
        try Self.insert(event, taskID: id, in: db)
        return promoted
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }
}

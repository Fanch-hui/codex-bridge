import BridgeDomain
import Foundation
import GRDB

public struct ServiceTaskListActivity: Sendable {
  public let events: [TaskID: [ServiceTaskEventRecord]]
  public let messages: [TaskID: [ServiceTaskMessageRecord]]
  public let messagesAvailable: Bool
}

extension ServiceStoreSchema {
  /// 查询与部分索引共用同一表达式文本：SQLite 逐项比较 WHERE 子句才会选用部分索引。
  static let nonterminalTaskPredicate = "status NOT IN ('completed', 'failed', 'interrupted')"

  /// 仅含未结束任务的部分索引，让 `nonterminalTasks` 不再随历史任务数线性扫描。
  /// 与其他纯性能索引一致，幂等创建、不改变 schema 版本，旧版本可继续打开数据库。
  static func ensureNonterminalTaskIndex(_ database: DatabaseQueue) throws {
    try database.write { db in
      try db.execute(
        sql: """
          CREATE INDEX IF NOT EXISTS bridge_service_tasks_nonterminal
          ON bridge_service_tasks(updated_at DESC, task_id)
          WHERE \(nonterminalTaskPredicate)
          """
      )
    }
  }
}

extension SimpleServiceStore {
  public func nonterminalTasks() throws -> [ServiceTaskRecord] {
    do {
      return try database.read { db in
        try Row.fetchAll(
          db,
          sql: """
            SELECT * FROM bridge_service_tasks
            WHERE \(ServiceStoreSchema.nonterminalTaskPredicate)
            ORDER BY updated_at DESC, task_id
            """
        ).map(Self.decodeTask)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func taskListActivity(taskIDs: [TaskID]) throws -> ServiceTaskListActivity {
    guard taskIDs.count <= 500 else {
      throw ServiceStoreError.invalidArgument("tasks.limit")
    }
    guard !taskIDs.isEmpty else {
      return ServiceTaskListActivity(events: [:], messages: [:], messagesAvailable: true)
    }
    let placeholders = Array(repeating: "?", count: taskIDs.count).joined(separator: ",")
    let arguments = StatementArguments(taskIDs.map(\.rawValue))
    do {
      return try database.read { db in
        let events = try Row.fetchAll(
          db,
          sql: """
            SELECT * FROM (
              SELECT *, ROW_NUMBER() OVER (PARTITION BY task_id ORDER BY event_id DESC) AS rank
              FROM bridge_service_task_events WHERE task_id IN (\(placeholders))
            ) WHERE rank <= 6 ORDER BY event_id ASC
            """,
          arguments: arguments
        ).map(Self.decodeEvent)
        let messages = Self.fetchRecentAgentMessages(
          for: taskIDs,
          in: db
        )
        return ServiceTaskListActivity(
          events: Dictionary(grouping: events, by: \.taskID),
          messages: Dictionary(grouping: messages ?? [], by: \.taskID),
          messagesAvailable: messages != nil
        )
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  private static func fetchRecentAgentMessages(
    for taskIDs: [TaskID],
    in database: Database
  ) -> [ServiceTaskMessageRecord]? {
    let chunkSize = 100
    var rows: [Row] = []
    for offset in stride(from: 0, to: taskIDs.count, by: chunkSize) {
      let end = min(offset + chunkSize, taskIDs.count)
      let chunk = Array(taskIDs[offset..<end])
      let query = chunk.map { _ in
        """
        SELECT * FROM (
          SELECT * FROM bridge_service_task_messages
          WHERE task_id = ? AND role = 'agent'
          ORDER BY updated_at DESC, message_id DESC
          LIMIT 8
        )
        """
      }.joined(separator: " UNION ALL ")
      guard
        let chunkRows = try? Row.fetchAll(
          database,
          sql: "SELECT * FROM (\(query)) ORDER BY updated_at ASC, message_id ASC",
          arguments: StatementArguments(chunk.map(\.rawValue))
        )
      else {
        return nil
      }
      rows.append(contentsOf: chunkRows)
    }
    return try? rows.map(Self.decodeTaskMessage).sorted {
      if $0.updatedAt != $1.updatedAt {
        return $0.updatedAt < $1.updatedAt
      }
      return $0.id < $1.id
    }
  }
}

import BridgeDomain
import Foundation
import GRDB

public struct ServiceTaskListActivity: Sendable {
  public let events: [TaskID: [ServiceTaskEventRecord]]
  public let messages: [TaskID: [ServiceTaskMessageRecord]]
  public let messagesAvailable: Bool
}

extension SimpleServiceStore {
  public func nonterminalTasks() throws -> [ServiceTaskRecord] {
    do {
      return try database.read { db in
        try Row.fetchAll(
          db,
          sql: """
            SELECT * FROM bridge_service_tasks
            WHERE status NOT IN ('completed', 'failed', 'interrupted')
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

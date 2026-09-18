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
        let messages = try? Row.fetchAll(
          db,
          sql: """
            SELECT * FROM (
              SELECT *, ROW_NUMBER() OVER (
                PARTITION BY task_id ORDER BY updated_at DESC, message_id DESC
              ) AS rank
              FROM bridge_service_task_messages WHERE task_id IN (\(placeholders)) AND role = 'agent'
            ) WHERE rank <= 8 ORDER BY updated_at ASC, message_id ASC
            """,
          arguments: arguments
        ).map(Self.decodeTaskMessage)
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
}

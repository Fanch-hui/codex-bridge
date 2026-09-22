import BridgeDomain
import GRDB

extension SimpleServiceStore {
  public func handoffAcknowledged(taskID: TaskID, handoffID: String) throws -> Bool {
    let marker = "\nHANDOFF-ACK: " + handoffID + "\n"
    return try database.read { db in
      try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS(SELECT 1 FROM bridge_service_task_messages
            WHERE task_id = ? AND role = 'agent' AND kind = 'agent'
              AND instr(char(10) || replace(content, char(13), '') || char(10), ?) > 0)
          """, arguments: [taskID.rawValue, marker]) ?? false
    }
  }
}

extension ServiceTaskManager {
  public func handoffAcknowledged(taskID: TaskID, handoffID: String) async throws -> Bool {
    try await store.handoffAcknowledged(taskID: taskID, handoffID: handoffID)
  }
}

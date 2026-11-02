import Foundation
import GRDB

public struct WorkbenchTaskSearchHit: Equatable, Sendable {
  public let taskID: String
  public let projectID: String
  public let providerID: String
  public let title: String
  public let excerpt: String
  public let messageID: Int64?
  public let messageKey: String?
}

extension SimpleServiceStore {
  public func searchWorkbenchTasks(
    query: String, projectID: String? = nil, limit: Int, offset: Int
  ) throws -> [WorkbenchTaskSearchHit] {
    let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !search.isEmpty, search.utf8.count <= 1024, !search.contains("\0"),
      (1...20).contains(limit), (0...1_000_000).contains(offset)
    else { throw ServiceStoreError.invalidArgument("workbench.search") }
    do {
      return try database.read { db in
        try Row.fetchAll(
          db,
          sql: """
            SELECT t.task_id, t.project_id, t.provider_id,
                   substr(t.prompt, 1, 120) AS title,
                   m.message_id, m.message_key,
                   CASE WHEN m.message_id IS NOT NULL
                     THEN substr(m.content, max(instr(lower(m.content), lower(?)) - 80, 1), 240)
                     ELSE substr(t.prompt, max(instr(lower(t.prompt), lower(?)) - 80, 1), 240)
                   END AS excerpt
            FROM bridge_service_tasks t
            JOIN bridge_service_projects p ON p.project_id = t.project_id
            LEFT JOIN bridge_service_task_messages m ON m.message_id = (
              SELECT candidate.message_id FROM bridge_service_task_messages candidate
              WHERE candidate.task_id = t.task_id AND candidate.kind IN ('user', 'agent')
                AND instr(lower(candidate.content), lower(?)) > 0
              ORDER BY candidate.message_id DESC LIMIT 1
            )
            WHERE (? IS NULL OR t.project_id = ?)
              AND (instr(lower(t.prompt), lower(?)) > 0 OR m.message_id IS NOT NULL)
            ORDER BY t.updated_at DESC, t.task_id
            LIMIT ? OFFSET ?
            """, arguments: [search, search, search, projectID, projectID, search, limit, offset]
        )
        .map { row in
          WorkbenchTaskSearchHit(
            taskID: row["task_id"], projectID: row["project_id"],
            providerID: row["provider_id"], title: row["title"], excerpt: row["excerpt"],
            messageID: row["message_id"], messageKey: row["message_key"])
        }
      }
    } catch let error as ServiceStoreError { throw error } catch {
      throw ServiceStoreError.storageFailure
    }
  }
}

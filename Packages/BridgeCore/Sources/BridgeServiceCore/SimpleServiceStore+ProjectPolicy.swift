import BridgeDomain
import BridgeProjects
import Foundation
import GRDB

extension SimpleServiceStore {
  public func updateProjectAccessPolicy(
    _ policy: ProjectAccessPolicy,
    projectID: ProjectID,
    at date: Date
  ) throws -> ServiceProjectRecord {
    try ServiceValidation.projectPolicy(policy)
    try ServiceValidation.date(date, field: "project.updatedAt")
    do {
      return try database.write { db in
        guard let row = try Self.projectRow(id: projectID, in: db) else {
          throw ServiceStoreError.unknownProject(projectID)
        }
        let existing = try Self.decodeProject(row)
        let updated = try existing.updatingAccessPolicy(policy, at: max(date, existing.updatedAt))
        try db.execute(
          sql: """
            UPDATE bridge_service_projects
            SET read_permission = ?, write_permission = ?, network_permission = ?, updated_at = ?
            WHERE project_id = ?
            """,
          arguments: [
            policy.read.rawValue, policy.write.rawValue, policy.network.rawValue,
            updated.updatedAt.timeIntervalSince1970, projectID.rawValue,
          ]
        )
        return updated
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }
}

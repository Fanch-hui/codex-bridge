import BridgeDomain
import Foundation
import GRDB

extension SimpleServiceStore {
  /// Points an existing project at a replacement root while keeping its ID, tasks and settings.
  /// Only for directories Bridge owns and recreated itself (the default workspace); user
  /// projects keep the strict identity check and are never rebound this way.
  public func rebindProjectRoot(
    projectID: ProjectID,
    expected: ServiceRootIdentity,
    replacement: ServiceRootIdentity
  ) throws {
    do {
      try database.write { db in
        guard let row = try Self.projectRow(id: projectID, in: db) else {
          throw ServiceStoreError.unknownProject(projectID)
        }
        guard try Self.decodeProject(row).root == expected else {
          throw ServiceStoreError.invalidArgument("project.rootRebind")
        }
        let occupied =
          try Int.fetchOne(
            db,
            sql: """
              SELECT COUNT(*) FROM bridge_service_projects
              WHERE project_id <> ? AND (canonical_path = ? OR (root_device = ? AND root_inode = ?))
              """,
            arguments: [
              projectID.rawValue, replacement.canonicalPath,
              String(replacement.device), String(replacement.inode),
            ]
          ) ?? 0
        guard occupied == 0 else {
          throw ServiceStoreError.duplicateProjectRoot(replacement.canonicalPath)
        }
        try db.execute(
          sql: """
            UPDATE bridge_service_projects
            SET canonical_path = ?, root_device = ?, root_inode = ?, root_volume_uuid = ?
            WHERE project_id = ?
            """,
          arguments: [
            replacement.canonicalPath,
            String(replacement.device),
            String(replacement.inode),
            replacement.volumeUUID,
            projectID.rawValue,
          ]
        )
        guard db.changesCount == 1 else { throw ServiceStoreError.storageFailure }
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }
}

import Foundation
import GRDB

extension SimpleServiceStore {
  public func workbenchTask(clientRequestID: String) throws -> ServiceTaskRecord? {
    try ServiceValidation.identifier(
      clientRequestID, field: "task.clientRequestID", maximumBytes: 256)
    do {
      return try database.read { db in
        try Row.fetchOne(
          db,
          sql: """
            SELECT * FROM bridge_service_tasks
            WHERE source = ? AND source_client_id = '' AND client_request_id = ?
            """,
          arguments: [ServiceTaskSource.macOSApp.rawValue, clientRequestID]
        ).map(Self.decodeTask)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }
}

extension ServiceTaskManager {
  public func workbenchTask(clientRequestID: String) async throws -> ServiceTaskRecord? {
    try await store.workbenchTask(clientRequestID: clientRequestID)
  }
}

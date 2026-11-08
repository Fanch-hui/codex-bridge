import Foundation
import GRDB

extension SimpleServiceStore {
  /// Reads many settings in one transaction. Keys with no stored value are absent from the result.
  public func settingRecords(keys: [String]) throws -> [String: ServiceSettingRecord] {
    let unique = Array(Set(keys))
    for key in unique {
      try ServiceValidation.identifier(key, field: "setting.key", maximumBytes: 128)
    }
    guard !unique.isEmpty else { return [:] }
    do {
      return try database.read { db in
        var result: [String: ServiceSettingRecord] = [:]
        for offset in stride(from: 0, to: unique.count, by: 400) {
          let chunk = Array(unique[offset..<min(offset + 400, unique.count)])
          let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
          let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM bridge_service_settings WHERE setting_key IN (\(placeholders))",
            arguments: StatementArguments(chunk))
          for row in rows {
            let record = try Self.decodeSetting(row)
            result[record.key] = record
          }
        }
        return result
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }
}

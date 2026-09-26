import Foundation
import GRDB

extension SimpleServiceStore {
  func settingValues(keys: [String]) throws -> [String: String] {
    for key in keys {
      try ServiceValidation.identifier(key, field: "setting.key", maximumBytes: 128)
    }
    do {
      return try database.read { db in
        var result: [String: String] = [:]
        for key in keys {
          if let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM bridge_service_settings WHERE setting_key = ?",
            arguments: [key]
          ) {
            let setting = try Self.decodeSetting(row)
            result[key] = setting.value
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

  func updateSettingsAtomically(
    keys: [String],
    updatedAt: Date,
    transform: @Sendable ([String: String]) throws -> [String: String]
  ) throws {
    for key in keys {
      try ServiceValidation.identifier(key, field: "setting.key", maximumBytes: 128)
    }
    do {
      try database.write { db in
        var current: [String: String] = [:]
        for key in keys {
          if let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM bridge_service_settings WHERE setting_key = ?",
            arguments: [key]
          ) {
            current[key] = try Self.decodeSetting(row).value
          }
        }
        let updated = try transform(current)
        for key in keys {
          guard let value = updated[key] else { continue }
          try db.execute(
            sql: """
              INSERT INTO bridge_service_settings (setting_key, setting_value, updated_at)
              VALUES (?, ?, ?)
              ON CONFLICT(setting_key) DO UPDATE SET
                setting_value = excluded.setting_value,
                updated_at = excluded.updated_at
              """,
            arguments: [key, value, updatedAt.timeIntervalSince1970]
          )
        }
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func setSetting(_ setting: ServiceSettingRecord) throws {
    try setSettings([setting])
  }

  func setSettings(_ settings: [ServiceSettingRecord]) throws {
    do {
      try database.write { db in
        for setting in settings {
          try db.execute(
            sql: """
              INSERT INTO bridge_service_settings (setting_key, setting_value, updated_at)
              VALUES (?, ?, ?)
              ON CONFLICT(setting_key) DO UPDATE SET
                setting_value = excluded.setting_value,
                updated_at = excluded.updated_at
              """,
            arguments: [setting.key, setting.value, setting.updatedAt.timeIntervalSince1970]
          )
        }
      }
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func setting(key: String) throws -> ServiceSettingRecord? {
    try ServiceValidation.identifier(key, field: "setting.key", maximumBytes: 128)
    do {
      return try database.read { db in
        try Row.fetchOne(
          db,
          sql: "SELECT * FROM bridge_service_settings WHERE setting_key = ?",
          arguments: [key]
        ).map(Self.decodeSetting)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }
}

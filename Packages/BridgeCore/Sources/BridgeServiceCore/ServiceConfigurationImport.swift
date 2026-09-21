import BridgeAgentCore
import BridgeDomain
import Foundation
import GRDB

public struct ServiceConfigurationImportBatch: Sendable {
  public let marker: ServiceSettingRecord
  public let projects: [ServiceProjectRecord]
  public let settings: [ServiceSettingRecord]

  public init(
    marker: ServiceSettingRecord,
    projects: [ServiceProjectRecord],
    settings: [ServiceSettingRecord]
  ) throws {
    guard !settings.contains(where: { $0.key == marker.key }) else {
      throw ServiceStoreError.invalidArgument("configurationImport.marker")
    }
    guard Set(projects.map(\.id)).count == projects.count,
      Set(settings.map(\.key)).count == settings.count
    else {
      throw ServiceStoreError.invalidArgument("configurationImport.duplicates")
    }
    self.marker = marker
    self.projects = projects
    self.settings = settings
  }
}

public struct ServiceConfigurationImportResult: Equatable, Sendable {
  public let alreadyApplied: Bool
  public let insertedProjectIDs: [ProjectID]
  public let existingProjectIDs: [ProjectID]
  public let skippedProjectIDs: [ProjectID]
  public let insertedSettingKeys: [String]
  public let existingSettingKeys: [String]

  public init(
    alreadyApplied: Bool,
    insertedProjectIDs: [ProjectID] = [],
    existingProjectIDs: [ProjectID] = [],
    skippedProjectIDs: [ProjectID] = [],
    insertedSettingKeys: [String] = [],
    existingSettingKeys: [String] = []
  ) {
    self.alreadyApplied = alreadyApplied
    self.insertedProjectIDs = insertedProjectIDs
    self.existingProjectIDs = existingProjectIDs
    self.skippedProjectIDs = skippedProjectIDs
    self.insertedSettingKeys = insertedSettingKeys
    self.existingSettingKeys = existingSettingKeys
  }
}

extension SimpleServiceStore {
  public func importConfiguration(
    _ batch: ServiceConfigurationImportBatch
  ) throws -> ServiceConfigurationImportResult {
    do {
      return try database.write { db in
        if try Self.settingRow(key: batch.marker.key, in: db) != nil {
          return ServiceConfigurationImportResult(alreadyApplied: true)
        }
        var result = ServiceConfigurationImportAccumulator()
        for project in batch.projects {
          do {
            try Self.importProject(project, result: &result, in: db)
          } catch let error as ServiceStoreError {
            switch error {
            case .duplicateProject, .duplicateProjectRoot:
              result.skippedProjectIDs.append(project.id)
            default:
              throw error
            }
          }
        }
        for setting in batch.settings {
          try Self.importSetting(setting, result: &result, in: db)
        }
        try Self.insertSetting(batch.marker, in: db)
        return result.result
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func hasConfigurationImportMarker(_ key: String) throws -> Bool {
    try ServiceValidation.identifier(key, field: "configurationImport.marker", maximumBytes: 128)
    do {
      return try database.read { db in
        try Self.settingRow(key: key, in: db) != nil
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  private static func importProject(
    _ project: ServiceProjectRecord,
    result: inout ServiceConfigurationImportAccumulator,
    in db: Database
  ) throws {
    if let row = try projectRow(id: project.id, in: db) {
      let existing = try decodeProject(row)
      guard pathsMatch(existing.root.canonicalPath, project.root.canonicalPath) else {
        throw ServiceStoreError.duplicateProject(project.id)
      }
      result.existingProjectIDs.append(project.id)
      return
    }
    if try hasEquivalentProjectRoot(project.root.canonicalPath, in: db) {
      throw ServiceStoreError.duplicateProjectRoot(project.root.canonicalPath)
    }
    try insert(project, in: db)
    result.insertedProjectIDs.append(project.id)
  }

  private static func importSetting(
    _ setting: ServiceSettingRecord,
    result: inout ServiceConfigurationImportAccumulator,
    in db: Database
  ) throws {
    guard try settingRow(key: setting.key, in: db) == nil else {
      result.existingSettingKeys.append(setting.key)
      return
    }
    try insertSetting(setting, in: db)
    result.insertedSettingKeys.append(setting.key)
  }

  private static func settingRow(key: String, in db: Database) throws -> Row? {
    try Row.fetchOne(
      db,
      sql: "SELECT * FROM bridge_service_settings WHERE setting_key = ?",
      arguments: [key]
    )
  }

  private static func hasEquivalentProjectRoot(
    _ canonicalPath: String,
    in db: Database
  ) throws -> Bool {
    let paths = try String.fetchAll(
      db,
      sql: "SELECT canonical_path FROM bridge_service_projects"
    )
    return paths.contains { pathsMatch($0, canonicalPath) }
  }

  private static func pathsMatch(_ lhs: String, _ rhs: String) -> Bool {
    AgentPathSemantics.relativePath(lhs, from: rhs) == ""
      && AgentPathSemantics.relativePath(rhs, from: lhs) == ""
  }

  private static func insertSetting(
    _ setting: ServiceSettingRecord,
    in db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO bridge_service_settings (setting_key, setting_value, updated_at)
        VALUES (?, ?, ?)
        """,
      arguments: [
        setting.key,
        setting.value,
        setting.updatedAt.timeIntervalSince1970,
      ]
    )
  }
}

private struct ServiceConfigurationImportAccumulator {
  var insertedProjectIDs: [ProjectID] = []
  var existingProjectIDs: [ProjectID] = []
  var skippedProjectIDs: [ProjectID] = []
  var insertedSettingKeys: [String] = []
  var existingSettingKeys: [String] = []

  var result: ServiceConfigurationImportResult {
    ServiceConfigurationImportResult(
      alreadyApplied: false,
      insertedProjectIDs: insertedProjectIDs,
      existingProjectIDs: existingProjectIDs,
      skippedProjectIDs: skippedProjectIDs,
      insertedSettingKeys: insertedSettingKeys,
      existingSettingKeys: existingSettingKeys
    )
  }
}

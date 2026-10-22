import BridgeServiceCore
import BridgeTunnel
import Foundation

struct LegacyOnboardingReader {
  let data: Data
  let date: Date

  func settings() throws -> [ServiceSettingRecord] {
    guard !data.isEmpty else { throw LegacyImportError.corruptOnboardingState }
    let record: LegacyOnboardingRecord
    do {
      record = try JSONDecoder().decode(LegacyOnboardingRecord.self, from: data)
    } catch {
      throw LegacyImportError.corruptOnboardingState
    }
    guard record.schemaVersion == 1 else {
      throw LegacyImportError.corruptOnboardingState
    }
    guard record.connectionMode == .secureTunnel,
      let tunnelID = record.tunnelID
    else {
      return []
    }
    guard (try? TunnelID(validating: tunnelID)) != nil else {
      throw LegacyImportError.corruptOnboardingState
    }
    return [
      try ServiceSettingRecord(
        key: ServiceSettingKey.tunnelID.rawValue,
        value: tunnelID,
        updatedAt: date
      ),
      try ServiceSettingRecord(
        key: ServiceSettingKey.tunnelEnabled.rawValue,
        value: "0",
        updatedAt: date
      ),
    ]
  }
}

private struct LegacyOnboardingRecord: Decodable {
  let schemaVersion: Int
  let connectionMode: LegacyConnectionMode?
  let tunnelID: String?
}

private enum LegacyConnectionMode: String, Decodable {
  case secureTunnel
  case manualHTTPS
  case localDevelopment
}

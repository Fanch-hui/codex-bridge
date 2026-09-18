import BridgeAgentCore
import Foundation

extension ServiceAgentRegistry {
  struct DisplayValidation {
    let record: ServiceAgentInstallationRecord
    let metadata: [String]
    let checkedAt: Date
  }

  public func refreshForDisplay(
    installationID: AgentInstallationID
  ) async throws -> ServiceAgentInstallationRecord {
    guard let record = try await store.agentInstallation(id: installationID) else {
      throw ServiceStoreError.unknownAgentInstallation(installationID)
    }
    let paths = [record.executablePath] + record.artifacts.map { $0.identity.canonicalPath }
    let metadata = try? Self.displayMetadata(paths)
    if let metadata, let cached = displayValidations[installationID],
      cached.record == record, cached.metadata == metadata,
      now().timeIntervalSince(cached.checkedAt) < 30
    {
      return record
    }
    let updated = try await refreshedRecord(record)
    if let metadata {
      displayValidations[installationID] = DisplayValidation(
        record: updated, metadata: metadata, checkedAt: now())
    } else {
      displayValidations.removeValue(forKey: installationID)
    }
    return updated
  }

  private static func displayMetadata(_ paths: [String]) throws -> [String] {
    try paths.flatMap { path in
      let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
      let values = try FileManager.default.attributesOfItem(atPath: canonical)
      return [canonical]
        + [.size, .modificationDate, .systemNumber, .systemFileNumber].map {
          String(describing: values[$0])
        }
    }
  }
}

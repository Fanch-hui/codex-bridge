import BridgeAgentCore
import Foundation

extension ServiceSettings {
  public func qoderInstallationDistribution(
    installationID: String
  ) async throws -> QoderDistribution? {
    try ServiceValidation.identifier(
      installationID,
      field: "agent.qoder.installation_id",
      maximumBytes: 256
    )
    let values = try await qoderSettingsSnapshot(keys: [.qoderInstallationDistributions])
    return try Self.distributionMap(
      values[ServiceSettingKey.qoderInstallationDistributions.rawValue])[
        installationID
      ]
  }

  public func setQoderInstallationDistribution(
    installationID: String,
    distribution: QoderDistribution
  ) async throws {
    try ServiceValidation.identifier(
      installationID,
      field: "agent.qoder.installation_id",
      maximumBytes: 256
    )
    try await updateDistributionMap(
      installationID,
      distribution: distribution,
      setting: .qoderInstallationDistributions
    )
  }

  public func qoderExecutableDistribution(path: String) async throws -> QoderDistribution? {
    let key = try Self.qoderExecutablePathKey(path)
    let values = try await qoderSettingsSnapshot(keys: [.qoderExecutableDistributions])
    return try Self.distributionMap(
      values[ServiceSettingKey.qoderExecutableDistributions.rawValue])[key]
  }

  public func setQoderExecutableDistribution(
    path: String,
    distribution: QoderDistribution
  ) async throws {
    let key = try Self.qoderExecutablePathKey(path)
    try await updateDistributionMap(
      key,
      distribution: distribution,
      setting: .qoderExecutableDistributions
    )
  }

  private func updateDistributionMap(
    _ key: String,
    distribution: QoderDistribution,
    setting: ServiceSettingKey
  ) async throws {
    try await updateQoderSettingsAtomically(keys: [setting]) { values in
      var distributions = try Self.distributionMap(values[setting.rawValue])
      distributions[key] = distribution
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      guard let data = try? encoder.encode(distributions.mapValues(\.rawValue)),
        let encoded = String(data: data, encoding: .utf8)
      else { throw ServiceStoreError.invalidArgument(setting.rawValue) }
      var updated = values
      updated[setting.rawValue] = encoded
      return updated
    }
  }

  private static func distributionMap(_ value: String?) throws -> [String: QoderDistribution] {
    guard let value, let data = value.data(using: .utf8) else { return [:] }
    guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
      throw ServiceStoreError.corruptRecord
    }
    var result: [String: QoderDistribution] = [:]
    for (key, rawValue) in decoded {
      guard let distribution = QoderDistribution(rawValue: rawValue) else {
        throw ServiceStoreError.corruptRecord
      }
      result[key] = distribution
    }
    return result
  }

  private static func qoderExecutablePathKey(_ path: String) throws -> String {
    try ServiceValidation.absolutePath(path, field: "agent.qoder.executable_path")
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    let canonical = AgentPathSemantics.canonicalPath(resolved) ?? resolved
    #if os(Windows)
      return canonical.replacingOccurrences(of: "\\", with: "/").lowercased()
    #else
      return canonical
    #endif
  }
}

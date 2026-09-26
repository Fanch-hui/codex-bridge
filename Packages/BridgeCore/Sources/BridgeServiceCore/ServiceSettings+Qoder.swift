import BridgeAgentCore
import Foundation

public struct ServiceQoderRuntimeSettings: Equatable, Sendable {
  public let distribution: QoderDistribution
  public let activeInstallationID: String?
  public let nodeExecutablePath: String?
  public let sdkRoot: String?

  public init(
    distribution: QoderDistribution,
    activeInstallationID: String? = nil,
    nodeExecutablePath: String? = nil,
    sdkRoot: String? = nil
  ) {
    self.distribution = distribution
    self.activeInstallationID = activeInstallationID
    self.nodeExecutablePath = nodeExecutablePath
    self.sdkRoot = sdkRoot
  }
}

public struct ServiceQoderRuntimeSettingsSnapshot: Equatable, Sendable {
  public let selectedDistribution: QoderDistribution?
  public let regions: [QoderDistribution: ServiceQoderRuntimeSettings]
}

private struct QoderRuntimeState: Codable, Sendable {
  var selectedDistribution: QoderDistribution?
  var regions: [String: QoderRegionState]

  static let empty = QoderRuntimeState(selectedDistribution: nil, regions: [:])
}

private struct QoderRegionState: Codable, Sendable {
  let activeInstallationID: String?
  let nodeExecutablePath: String?
  let sdkRoot: String?

  init(_ settings: ServiceQoderRuntimeSettings) {
    activeInstallationID = settings.activeInstallationID
    nodeExecutablePath = settings.nodeExecutablePath
    sdkRoot = settings.sdkRoot
  }

  func settings(for distribution: QoderDistribution) -> ServiceQoderRuntimeSettings {
    ServiceQoderRuntimeSettings(
      distribution: distribution,
      activeInstallationID: activeInstallationID,
      nodeExecutablePath: nodeExecutablePath,
      sdkRoot: sdkRoot
    )
  }
}

extension ServiceSettings {
  public func qoderRuntimeSettings(
    distribution requested: QoderDistribution? = nil
  ) async throws -> ServiceQoderRuntimeSettings {
    let snapshot = try await qoderRuntimeSettingsSnapshot()
    let distribution = requested ?? snapshot.selectedDistribution ?? .cn
    guard let region = snapshot.regions[distribution] else {
      throw ServiceStoreError.corruptRecord
    }
    return region
  }

  public func configuredQoderDistribution() async throws -> QoderDistribution? {
    let snapshot = try await qoderRuntimeSettingsSnapshot()
    return snapshot.selectedDistribution
  }

  public func qoderRuntimeSettingsSnapshot() async throws -> ServiceQoderRuntimeSettingsSnapshot {
    let values = try await qoderSettingsSnapshot(keys: Self.qoderRuntimeKeys)
    let state = try Self.runtimeState(values[ServiceSettingKey.qoderRuntimeState.rawValue])
    var regions: [QoderDistribution: ServiceQoderRuntimeSettings] = [:]
    for distribution in QoderDistribution.allCases {
      if let region = state.regions[distribution.rawValue] {
        regions[distribution] = region.settings(for: distribution)
      } else {
        regions[distribution] = Self.legacyRegionSettings(distribution, values: values)
      }
    }
    return ServiceQoderRuntimeSettingsSnapshot(
      selectedDistribution: try Self.selectedDistribution(state, values: values),
      regions: regions
    )
  }

  public func setQoderRuntimeSettings(
    _ value: ServiceQoderRuntimeSettings
  ) async throws {
    try await updateQoderRuntimeSettings(value, selectRegion: true)
  }

  public func setQoderRegionSettings(
    _ value: ServiceQoderRuntimeSettings
  ) async throws {
    try await updateQoderRuntimeSettings(value, selectRegion: false)
  }

  private func updateQoderRuntimeSettings(
    _ value: ServiceQoderRuntimeSettings,
    selectRegion: Bool
  ) async throws {
    let normalized = try Self.normalized(value)
    let keys = Self.regionKeys(normalized.distribution)
    try await updateQoderSettingsAtomically(keys: keys) { values in
      var state = try Self.runtimeState(values[ServiceSettingKey.qoderRuntimeState.rawValue])
      state.regions[normalized.distribution.rawValue] = QoderRegionState(normalized)
      if selectRegion { state.selectedDistribution = normalized.distribution }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      guard let data = try? encoder.encode(state),
        let encoded = String(data: data, encoding: .utf8)
      else { throw ServiceStoreError.invalidArgument(ServiceSettingKey.qoderRuntimeState.rawValue) }
      var updated = values
      updated[ServiceSettingKey.qoderRuntimeState.rawValue] = encoded
      updated[Self.activeInstallationKey(normalized.distribution).rawValue] =
        normalized.activeInstallationID ?? ""
      updated[Self.nodeExecutableKey(normalized.distribution).rawValue] =
        normalized.nodeExecutablePath ?? ""
      updated[Self.sdkRootKey(normalized.distribution).rawValue] = normalized.sdkRoot ?? ""
      if selectRegion {
        updated[ServiceSettingKey.qoderDistribution.rawValue] = normalized.distribution.rawValue
      }
      return updated
    }
  }

  private static let qoderRuntimeKeys: [ServiceSettingKey] = [
    .qoderRuntimeState, .qoderDistribution,
    .qoderCNActiveInstallationID, .qoderCNNodeExecutablePath, .qoderCNSDKRoot,
    .qoderInternationalActiveInstallationID, .qoderInternationalNodeExecutablePath,
    .qoderInternationalSDKRoot,
  ]

  private static func regionKeys(_ distribution: QoderDistribution) -> [ServiceSettingKey] {
    [
      .qoderRuntimeState, .qoderDistribution, activeInstallationKey(distribution),
      nodeExecutableKey(distribution), sdkRootKey(distribution),
    ]
  }

  private static func normalized(
    _ settings: ServiceQoderRuntimeSettings
  ) throws -> ServiceQoderRuntimeSettings {
    if let activeID = settings.activeInstallationID {
      try ServiceValidation.identifier(
        activeID,
        field: activeInstallationKey(settings.distribution).rawValue,
        maximumBytes: 256
      )
    }
    let nodePath = try validatedPath(
      settings.nodeExecutablePath,
      field: nodeExecutableKey(settings.distribution).rawValue)
    let sdkPath = try validatedPath(
      settings.sdkRoot, field: sdkRootKey(settings.distribution).rawValue)
    return ServiceQoderRuntimeSettings(
      distribution: settings.distribution,
      activeInstallationID: settings.activeInstallationID,
      nodeExecutablePath: nodePath,
      sdkRoot: sdkPath
    )
  }

  private static func legacyRegionSettings(
    _ distribution: QoderDistribution,
    values: [String: String]
  ) -> ServiceQoderRuntimeSettings {
    ServiceQoderRuntimeSettings(
      distribution: distribution,
      activeInstallationID: nonEmpty(values[activeInstallationKey(distribution).rawValue]),
      nodeExecutablePath: nonEmpty(values[nodeExecutableKey(distribution).rawValue]),
      sdkRoot: nonEmpty(values[sdkRootKey(distribution).rawValue])
    )
  }

  private static func selectedDistribution(
    _ state: QoderRuntimeState,
    values: [String: String]
  ) throws -> QoderDistribution? {
    if let selected = state.selectedDistribution { return selected }
    guard let value = values[ServiceSettingKey.qoderDistribution.rawValue], !value.isEmpty else {
      return nil
    }
    guard let distribution = QoderDistribution(rawValue: value) else {
      throw ServiceStoreError.corruptRecord
    }
    return distribution
  }

  private static func runtimeState(_ value: String?) throws -> QoderRuntimeState {
    guard let value, let data = value.data(using: .utf8) else { return .empty }
    guard let state = try? JSONDecoder().decode(QoderRuntimeState.self, from: data) else {
      throw ServiceStoreError.corruptRecord
    }
    return state
  }

  private static func validatedPath(_ value: String?, field: String) throws -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    try ServiceValidation.absolutePath(trimmed, field: field)
    return trimmed
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  private static func activeInstallationKey(_ distribution: QoderDistribution) -> ServiceSettingKey
  {
    distribution == .cn ? .qoderCNActiveInstallationID : .qoderInternationalActiveInstallationID
  }

  private static func nodeExecutableKey(_ distribution: QoderDistribution) -> ServiceSettingKey {
    distribution == .cn ? .qoderCNNodeExecutablePath : .qoderInternationalNodeExecutablePath
  }

  private static func sdkRootKey(_ distribution: QoderDistribution) -> ServiceSettingKey {
    distribution == .cn ? .qoderCNSDKRoot : .qoderInternationalSDKRoot
  }
}

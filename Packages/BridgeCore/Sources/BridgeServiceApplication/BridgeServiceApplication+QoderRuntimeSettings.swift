import BridgeAgentCore
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func serviceQoderRuntimeSettings(
    distribution requested: QoderDistribution? = nil,
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceQoderRuntimeSettings {
    try Self.checkDeadline(deadline)
    if let requested {
      return try await settings.qoderRuntimeSettings(distribution: requested)
    }
    if let distribution = try await settings.configuredQoderDistribution() {
      return try await settings.qoderRuntimeSettings(distribution: distribution)
    }

    let installations = try await requiredAgentRegistry().installations(providerID: .qoder)
      .filter(\.isSelectable)
    if installations.count == 1,
      let distribution = try await qoderDistribution(for: installations[0])
    {
      let selected = ServiceQoderRuntimeSettings(
        distribution: distribution,
        activeInstallationID: installations[0].id.rawValue
      )
      try await settings.setQoderInstallationDistribution(
        installationID: installations[0].id.rawValue,
        distribution: distribution
      )
      try await settings.setQoderRuntimeSettings(selected)
      return selected
    }
    return try await settings.qoderRuntimeSettings(distribution: .cn)
  }

  public func serviceSetQoderRuntimeSettings(
    _ value: ServiceQoderRuntimeSettings,
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceQoderRuntimeSettings {
    try Self.checkDeadline(deadline)
    if let installationID = value.activeInstallationID {
      guard
        let installation = try await requiredAgentRegistry().installation(
          id: AgentInstallationID(rawValue: installationID)),
        installation.providerID == .qoder, installation.isSelectable
      else {
        throw BridgeMCPQueryError.contractRejected
      }
      if let knownDistribution = try await qoderDistribution(for: installation),
        knownDistribution != value.distribution
      {
        throw BridgeMCPQueryError.contractRejected
      }
      try await settings.setQoderInstallationDistribution(
        installationID: installationID,
        distribution: value.distribution
      )
    }
    try await settings.setQoderRuntimeSettings(value)
    try Self.checkDeadline(deadline)
    return value
  }

  func qoderDistribution(
    for installation: ServiceAgentInstallationRecord
  ) async throws -> QoderDistribution? {
    if let configured = try await settings.qoderInstallationDistribution(
      installationID: installation.id.rawValue)
    {
      return configured
    }
    if let executable = QoderDistribution.identify(executablePath: installation.executablePath) {
      return executable
    }
    return QoderDistribution.identify(displayName: installation.displayName)
  }
}

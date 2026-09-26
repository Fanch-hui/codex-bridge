import BridgeAgentCore
import BridgeMCP
import BridgeServiceCore

extension BridgeServiceApplication {
  func agentDefaultSettings(
    providerID: AgentProviderID,
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceAgentDefaultSettings {
    guard providerID == .qoder else {
      return try ServiceAgentDefaultSettings.descriptor(for: providerID)
    }
    let runtime = try await serviceQoderRuntimeSettings(deadline: deadline)
    return try ServiceAgentDefaultSettings.descriptor(
      for: providerID, distribution: runtime.distribution)
  }

  func selectAgentInstallation(
    providerID: AgentProviderID,
    requested: String?,
    selectable: [ServiceAgentInstallationRecord],
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceAgentInstallationRecord {
    guard providerID == .qoder else {
      return try Self.selectAgentInstallation(requested: requested, from: selectable)
    }
    let explicitRecord: ServiceAgentInstallationRecord?
    if let requested {
      guard let record = selectable.first(where: { $0.id.rawValue == requested }) else {
        throw BridgeMCPQueryError.unavailable
      }
      explicitRecord = record
    } else {
      explicitRecord = nil
    }
    let runtime = try await serviceQoderRuntimeSettings(deadline: deadline)
    let distribution = runtime.distribution
    if let explicitRecord {
      guard try await qoderDistribution(for: explicitRecord) != nil else {
        throw BridgeMCPQueryError.contractRejected
      }
      return explicitRecord
    }
    if let activeID = runtime.activeInstallationID {
      guard let active = selectable.first(where: { $0.id.rawValue == activeID }),
        try await qoderDistribution(for: active) == distribution
      else { throw BridgeMCPQueryError.unavailable }
      return active
    }
    var regional: [ServiceAgentInstallationRecord] = []
    for installation in selectable {
      if try await qoderDistribution(for: installation) == distribution {
        regional.append(installation)
      }
    }
    guard regional.count == 1, let only = regional.first else {
      throw BridgeMCPQueryError.unavailable
    }
    return only
  }
}

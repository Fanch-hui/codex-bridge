import BridgeAgentCore
import BridgeDeepSeekHarnessACP
import BridgeIPC
import BridgeMCP
import BridgeServiceApplication
import BridgeServiceCore
import Foundation

extension BridgeServiceRequestController {
  func handleRegisterAgentInstallation(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCAgentRegistrationRequest.self, from: request)
    let providerID = AgentProviderID(rawValue: payload.providerID)
    let distribution: QoderDistribution?
    var executablePath = payload.executablePath
    if providerID == .qoder {
      guard let rawValue = payload.qoderDistribution,
        let selected = QoderDistribution(rawValue: rawValue),
        QoderDistribution.identify(executablePath: payload.executablePath).map({ $0 == selected })
          ?? true
      else { throw BridgeMCPQueryError.contractRejected }
      executablePath = try ServiceAgentAutoDiscovery.qoderExecutablePath(
        payload.executablePath, distribution: selected)
      if let existing = try await composition.settings.qoderExecutableDistribution(
        path: executablePath), existing != selected
      {
        throw BridgeMCPQueryError.contractRejected
      }
      try await composition.settings.setQoderExecutableDistribution(
        path: executablePath, distribution: selected)
      distribution = selected
    } else {
      distribution = nil
    }
    let policy = ServiceAgentProviderPolicyRegistry.policy(for: providerID)
    let artifacts = try Self.registrationArtifacts(
      providerID: providerID,
      executablePath: executablePath,
      configurationPath: payload.configurationPath
    )
    let record = try await composition.application.serviceRegisterManagedAgent(
      try ServiceAgentRegistrationRequest(
        providerID: providerID,
        displayName: distribution?.installationDisplayName ?? payload.displayName,
        executablePath: executablePath,
        trustProfile: policy?.registrationTrustProfile ?? .managed,
        securityProfileID: policy?.registrationSecurityProfileID,
        enableOnSuccess: false,
        configurationPath: payload.configurationPath,
        artifacts: artifacts
      ),
      deadline: Self.deadline()
    )
    if let distribution {
      try await composition.settings.setQoderInstallationDistribution(
        installationID: record.id.rawValue, distribution: distribution)
    }
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: Self.agentInstallationSummary(record, distribution: distribution?.rawValue)
    )
  }

  func handleConnectAgentInstallation(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(IPCAgentConnectRequest.self, from: request)
    let providerID = AgentProviderID(rawValue: payload.providerID)
    let distribution: QoderDistribution?
    if providerID == .qoder {
      guard let rawValue = payload.qoderDistribution,
        let selected = QoderDistribution(rawValue: rawValue)
      else { throw BridgeMCPQueryError.contractRejected }
      distribution = selected
    } else {
      distribution = nil
    }

    let existing = try await composition.agentRegistry.installations(providerID: providerID)
    let selectedInstallation = try await selectedQoderInstallation(
      payload: payload, distribution: distribution, existing: existing)
    let distributionMap = try await qoderDistributionsByExecutablePath(for: existing)
    let environment = ToolDiscoveryEnvironment.current()
    let discoveredPath = await discoveredAgentPath(
      providerID: providerID,
      distribution: distribution,
      selected: selectedInstallation,
      existing: existing,
      environment: environment,
      distributionMap: distributionMap
    )
    var candidates = try ServiceAgentAutoDiscovery.registrationRequests(
      providerID: providerID,
      dataPaths: composition.paths,
      existingInstallations: existing,
      credentialsProvided: payload.baseURL != nil || payload.apiKey != nil,
      environment: environment,
      discoveredExecutablePath: discoveredPath,
      qoderDistribution: distribution,
      qoderDistributionsByExecutablePath: distributionMap
    )
    if let selectedInstallation {
      candidates = candidates.filter { $0.executablePath == selectedInstallation.executablePath }
    }
    let record = try await composition.application.serviceConnectManagedAgent(
      providerID: providerID,
      baseURL: payload.baseURL,
      apiKey: payload.apiKey,
      candidates: candidates,
      qoderDistribution: distribution,
      alwaysProceedConfirmed: payload.alwaysProceedConfirmed,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: Self.agentInstallationSummary(record, distribution: distribution?.rawValue)
    )
  }

  func handleSetQoderRuntimeSettings(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCAgentQoderRuntimeSettingsRequest.self, from: request)
    guard let distribution = QoderDistribution(rawValue: payload.distribution) else {
      throw BridgeMCPQueryError.contractRejected
    }
    let updated = try await composition.application.serviceSetQoderRuntimeSettings(
      ServiceQoderRuntimeSettings(
        distribution: distribution,
        activeInstallationID: payload.activeInstallationID,
        nodeExecutablePath: payload.nodeExecutablePath,
        sdkRoot: payload.sdkRoot
      ),
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCAgentQoderRuntimeSettingsRequest(
        distribution: updated.distribution.rawValue,
        activeInstallationID: updated.activeInstallationID,
        nodeExecutablePath: updated.nodeExecutablePath,
        sdkRoot: updated.sdkRoot
      )
    )
  }

  private func selectedQoderInstallation(
    payload: IPCAgentConnectRequest,
    distribution: QoderDistribution?,
    existing: [ServiceAgentInstallationRecord]
  ) async throws -> ServiceAgentInstallationRecord? {
    guard let distribution else { return nil }
    let settings = try await composition.settings.qoderRuntimeSettings(distribution: distribution)
    if let requestedID = payload.installationID {
      guard
        let installation = existing.first(where: {
          $0.id.rawValue == requestedID && $0.availability == .available
        })
      else { throw BridgeMCPQueryError.unavailable }
      let byID = try await composition.settings.qoderInstallationDistribution(
        installationID: requestedID)
      let byPath = try await composition.settings.qoderExecutableDistribution(
        path: installation.executablePath)
      let identified =
        byID
        ?? byPath
        ?? QoderDistribution.identify(executablePath: installation.executablePath)
        ?? QoderDistribution.identify(displayName: installation.displayName)
      if let identified {
        guard identified == distribution else { throw BridgeMCPQueryError.contractRejected }
      } else {
        try await composition.settings.setQoderExecutableDistribution(
          path: installation.executablePath, distribution: distribution)
        try await composition.settings.setQoderInstallationDistribution(
          installationID: installation.id.rawValue, distribution: distribution)
      }
      return installation
    }
    if let activeID = settings.activeInstallationID {
      return try await qoderInstallation(
        id: activeID,
        distribution: distribution,
        existing: existing,
        mustBeSelectable: true
      )
    }

    var regional: [ServiceAgentInstallationRecord] = []
    for installation in existing where installation.availability == .available {
      let mapped = try await composition.settings.qoderInstallationDistribution(
        installationID: installation.id.rawValue)
      let identified =
        mapped
        ?? QoderDistribution.identify(executablePath: installation.executablePath)
        ?? QoderDistribution.identify(displayName: installation.displayName)
      if identified == distribution { regional.append(installation) }
    }
    guard regional.count <= 1 else { throw BridgeMCPQueryError.unavailable }
    return regional.first
  }

  private func qoderInstallation(
    id: String,
    distribution: QoderDistribution,
    existing: [ServiceAgentInstallationRecord],
    mustBeSelectable: Bool
  ) async throws -> ServiceAgentInstallationRecord {
    guard
      let installation = existing.first(where: {
        $0.id.rawValue == id && $0.availability == .available
          && (!mustBeSelectable || $0.isSelectable)
      })
    else { throw BridgeMCPQueryError.unavailable }
    let mapped = try await composition.settings.qoderInstallationDistribution(
      installationID: id)
    let executable = try await composition.settings.qoderExecutableDistribution(
      path: installation.executablePath)
    let identified =
      mapped
      ?? executable
      ?? QoderDistribution.identify(executablePath: installation.executablePath)
      ?? QoderDistribution.identify(displayName: installation.displayName)
    guard identified == distribution else { throw BridgeMCPQueryError.contractRejected }
    return installation
  }

  private func discoveredAgentPath(
    providerID: AgentProviderID,
    distribution: QoderDistribution?,
    selected: ServiceAgentInstallationRecord?,
    existing: [ServiceAgentInstallationRecord],
    environment: [String: String],
    distributionMap: [String: QoderDistribution]
  ) async -> String? {
    if let selected { return selected.executablePath }
    if let distribution {
      return try? ServiceAgentAutoDiscovery.discoverySummary(
        providerID: .qoder,
        existingInstallations: existing,
        environment: environment,
        qoderDistribution: distribution,
        qoderDistributionsByExecutablePath: distributionMap
      ).executablePath
    }
    let summaries = await composition.agentDiscoveryCatalog.summaries(
      providerIDs: [providerID], existingInstallations: existing)
    return summaries[providerID]?.executablePath
  }

  func qoderDistributionsByExecutablePath(
    for installations: [ServiceAgentInstallationRecord]
  ) async throws -> [String: QoderDistribution] {
    var result: [String: QoderDistribution] = [:]
    for installation in installations where installation.providerID == .qoder {
      let byID = try await composition.settings.qoderInstallationDistribution(
        installationID: installation.id.rawValue)
      let byPath = try await composition.settings.qoderExecutableDistribution(
        path: installation.executablePath)
      if let distribution = byID ?? byPath
        ?? QoderDistribution.identify(executablePath: installation.executablePath)
        ?? QoderDistribution.identify(displayName: installation.displayName)
      {
        result[installation.executablePath] = distribution
      }
    }
    return result
  }
}

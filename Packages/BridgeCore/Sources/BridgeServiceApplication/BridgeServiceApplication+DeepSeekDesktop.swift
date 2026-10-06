import BridgeAgentCore
import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

public struct ServiceDeepSeekDesktopState: Sendable {
  public let mode: DeepSeekHarnessConnectionMode
  public let desktop: DeepSeekHarnessDesktopStatus
  public let executablePath: String
  public let connectorInstalled: Bool
  public let canInstallConnector: Bool
}

extension BridgeServiceApplication {
  public func serviceConnectDeepSeekDesktop(
    _ candidate: ServiceAgentRegistrationRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceAgentInstallationRecord {
    try Self.checkDeadline(deadline)
    guard deepSeekDesktop != nil else {
      throw AgentRuntimeError.unsupportedProtocol("dsh_desktop_platform_unsupported")
    }
    let registry = try requiredAgentRegistry()
    guard candidate.providerID == .deepSeekHarness, candidate.configurationPath == nil else {
      throw BridgeMCPQueryError.contractRejected
    }
    let records = try await registry.installations(providerID: .deepSeekHarness)
    for record in records { try await requireIdleDeepSeekDesktopInstallation(record.id) }
    try await settings.set(
      DeepSeekHarnessConnectionMode.nativeDesktop.rawValue,
      for: .deepSeekHarnessConnectionMode)
    if let matching = records.first(where: {
      AgentPathSemantics.relativePath($0.executablePath, from: candidate.executablePath) == ""
    }) {
      try await settings.set(matching.id.rawValue, for: .deepSeekHarnessDesktopActiveInstallationID)
      return try await registry.reprobe(installationID: matching.id, acceptReplacement: false)
    }
    let record = try await registry.registerAndProbe(candidate)
    try await settings.set(record.id.rawValue, for: .deepSeekHarnessDesktopActiveInstallationID)
    return record
  }
  public func serviceDeepSeekDesktop(
    installationID: String, action: String = "status",
    mode: DeepSeekHarnessConnectionMode? = nil, projectID: String? = nil,
    sessionID: String? = nil, taskID: String? = nil, deadline: ContinuousClock.Instant
  ) async throws
    -> ServiceDeepSeekDesktopState
  {
    try Self.checkDeadline(deadline)
    guard let controller = deepSeekDesktop else {
      throw AgentRuntimeError.unsupportedProtocol("dsh_desktop_platform_unsupported")
    }
    let registry = try requiredAgentRegistry()
    let record = try await deepSeekDesktopInstallation(
      installationID: .init(rawValue: installationID), action: action, registry: registry)
    guard record.runtimeArtifacts.contains(where: { $0.role == .archive }) else {
      throw BridgeMCPQueryError.unavailable
    }
    let installation = try record.agentInstallation()
    var state: DeepSeekHarnessDesktopStatus
    switch action {
    case "status":
      state = await deepSeekDesktopStatus(controller, installation: installation)
    case "setMode":
      guard let mode else { throw BridgeMCPQueryError.contractRejected }
      try await requireIdleDeepSeekDesktopInstallation(record.id)
      try await settings.set(mode.rawValue, for: .deepSeekHarnessConnectionMode)
      if mode == .nativeDesktop {
        try await settings.set(record.id.rawValue, for: .deepSeekHarnessDesktopActiveInstallationID)
      }
      if mode == .acp {
        _ = try await registry.reprobe(installationID: record.id, acceptReplacement: false)
      }
      state = await deepSeekDesktopStatus(controller, installation: installation)
    case "installConnector":
      try await requireIdleDeepSeekDesktopInstallation(record.id)
      guard let installer = installDeepSeekDesktopConnector else {
        throw BridgeMCPQueryError.unavailable
      }
      try await installer(installation)
      state = await deepSeekDesktopStatus(controller, installation: installation)
    case "connect", "pair":
      try await requireIdleDeepSeekDesktopInstallation(record.id)
      state = try await controller.pair(installation: installation)
    case "revoke":
      try await requireIdleDeepSeekDesktopInstallation(record.id)
      try await controller.revoke(installation: installation)
      state = try await controller.status(installation: installation)
    case "openSession":
      let address = try await deepSeekDesktopSessionAddress(
        installationID: record.id,
        projectID: projectID, sessionID: sessionID, taskID: taskID)
      try await controller.openSession(
        sessionID: address.sessionID,
        projectRoot: address.projectRoot, installation: installation)
      state = try await controller.status(installation: installation)
    default: throw BridgeMCPQueryError.contractRejected
    }
    return try await deepSeekDesktopResult(installation: installation, state: state, action: action)
  }

  private func deepSeekDesktopInstallation(
    installationID: AgentInstallationID, action: String, registry: ServiceAgentRegistry
  ) async throws -> ServiceAgentInstallationRecord {
    if action == "connect" {
      guard let stored = try await registry.installation(id: installationID),
        stored.providerID == .deepSeekHarness,
        stored.runtimeArtifacts.contains(where: { $0.role == .archive })
      else { throw BridgeMCPQueryError.unavailable }
      try await requireIdleDeepSeekDesktopInstallation(installationID)
      _ = try await registry.reprobe(installationID: installationID, acceptReplacement: true)
    }
    return try await registry.validateDesktopInstallation(installationID: installationID)
  }

  private func deepSeekDesktopResult(
    installation: AgentInstallation, state: DeepSeekHarnessDesktopStatus, action: String
  ) async throws -> ServiceDeepSeekDesktopState {
    let registry = try requiredAgentRegistry()
    let currentMode = try await settings.deepSeekHarnessConnectionMode()
    if state.paired && state.connected && currentMode == .nativeDesktop,
      action == "connect" || action == "pair" || action == "status" || action == "setMode"
    {
      let probe = try await registry.reprobe(
        installationID: installation.id,
        acceptReplacement: false, projectRoot: nil)
      if probe.availability == .available {
        _ = try await registry.setEnabled(true, installationID: installation.id)
      }
    }
    return ServiceDeepSeekDesktopState(
      mode: currentMode, desktop: state,
      executablePath: installation.executablePath,
      connectorInstalled: isDeepSeekDesktopConnectorInstalled(installation),
      canInstallConnector: installDeepSeekDesktopConnector != nil)
  }

  private func deepSeekDesktopStatus(
    _ controller: any DeepSeekHarnessDesktopControlling,
    installation: AgentInstallation
  ) async -> DeepSeekHarnessDesktopStatus {
    do { return try await controller.status(installation: installation) } catch {
      let trust = try? await settings.deepSeekHarnessDesktopTrust(installationID: installation.id)
      return DeepSeekHarnessDesktopStatus(
        connected: false, paired: trust != nil,
        profileID: trust?.profileID, unavailableReason: "DSH Desktop Connector 不可用，请安装插件并启动桌面。")
    }
  }

  private func requireIdleDeepSeekDesktopInstallation(_ installationID: AgentInstallationID)
    async throws
  {
    guard
      try await tasks.nonterminalTasks().allSatisfy({
        $0.providerID != AgentProviderID.deepSeekHarness.rawValue
          || $0.installationID != installationID.rawValue
      })
    else { throw BridgeMCPQueryError.invalidTaskState }
  }

  private func deepSeekDesktopSessionAddress(
    installationID: AgentInstallationID,
    projectID: String?, sessionID: String?, taskID: String?
  ) async throws
    -> (sessionID: String, projectRoot: String)
  {
    let trust = try await settings.deepSeekHarnessDesktopTrust(installationID: installationID)
    guard let trust else { throw BridgeMCPQueryError.unavailable }
    if let taskID {
      guard let task = try await tasks.task(id: TaskID(rawValue: taskID)),
        task.providerID == AgentProviderID.deepSeekHarness.rawValue,
        task.installationID == installationID.rawValue,
        let binding = try await tasks.agentRuntimeBinding(taskID: task.id),
        binding.connectionMode == .nativeDesktop, binding.profileID == trust.profileID,
        let sessionID = task.state.providerSessionID ?? task.requestedThreadID
      else { throw BridgeMCPQueryError.taskNotFound }
      return (sessionID, try await readableProject(task.projectID.rawValue).root.canonicalPath)
    }
    guard let projectID, let sessionID, !sessionID.isEmpty, sessionID.utf8.count <= 256 else {
      throw BridgeMCPQueryError.contractRejected
    }
    let project = try await readableProject(projectID)
    return (sessionID, project.root.canonicalPath)
  }
}

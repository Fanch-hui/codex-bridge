import BridgeAgentCore
import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  func canOpenDeepSeekDesktopTask(_ task: ServiceTaskRecord) async throws -> Bool? {
    guard
      task.providerID == AgentProviderID.deepSeekHarness.rawValue
        || task.providerID == AgentProviderID.deepSeekHarnessDesktop.rawValue
    else { return nil }
    guard let binding = try await tasks.agentRuntimeBinding(taskID: task.id),
      binding.connectionMode == .nativeDesktop,
      let installationID = task.installationID,
      let trust = try await settings.deepSeekHarnessDesktopTrust(
        installationID: AgentInstallationID(rawValue: installationID))
    else { return false }
    return binding.profileID == trust.profileID
      && (task.state.providerSessionID ?? task.requestedThreadID) != nil
  }
  func runtimeBindingForTask(_ task: ServiceTaskRecord) async throws -> AgentRuntimeBinding? {
    guard
      task.providerID == AgentProviderID.deepSeekHarness.rawValue
        || task.providerID == AgentProviderID.deepSeekHarnessDesktop.rawValue
    else { return nil }
    if let binding = try await tasks.agentRuntimeBinding(taskID: task.id) { return binding }
    guard task.providerID == AgentProviderID.deepSeekHarness.rawValue else {
      throw BridgeMCPQueryError.contractRejected
    }
    return AgentRuntimeBinding(connectionMode: .acp, requestID: task.id.rawValue)
  }
  func deepSeekSubmissionRuntimeBinding(
    submission: MCPServiceTaskSubmission,
    record: ServiceAgentInstallationRecord, project: ServiceProjectRecord
  ) async throws
    -> AgentRuntimeBinding?
  {
    guard record.providerID == .deepSeekHarness || record.providerID == .deepSeekHarnessDesktop
    else { return nil }
    let source: ServiceTaskRecord?
    if let sourceID = submission.attachmentSourceTaskID {
      source = try await tasks.task(id: TaskID(rawValue: sourceID))
    } else if let sessionID = submission.threadID {
      source = try await tasks.task(
        providerSessionID: sessionID,
        providerID: record.providerID.rawValue, installationID: record.id.rawValue,
        projectID: project.id)
    } else {
      source = nil
    }
    let requestID = UUID().uuidString.lowercased()
    if let source {
      guard source.projectID == project.id, source.installationID == record.id.rawValue,
        source.providerID == record.providerID.rawValue
      else { throw BridgeMCPQueryError.contractRejected }
      let existing = try await tasks.agentRuntimeBinding(taskID: source.id)
      guard existing != nil || record.providerID == .deepSeekHarness else {
        throw BridgeMCPQueryError.contractRejected
      }
      return AgentRuntimeBinding(
        connectionMode: existing?.connectionMode ?? .acp,
        profileID: existing?.profileID, requestID: requestID)
    }
    let mode: DeepSeekHarnessConnectionMode =
      record.providerID == .deepSeekHarnessDesktop ? .nativeDesktop : .acp
    let profileID: String?
    if mode == .nativeDesktop {
      guard let trust = try await settings.deepSeekHarnessDesktopTrust(installationID: record.id)
      else { throw BridgeMCPQueryError.unavailable }
      profileID = trust.profileID
    } else {
      profileID = nil
    }
    return AgentRuntimeBinding(connectionMode: mode, profileID: profileID, requestID: requestID)
  }

  func refreshDeepSeekDesktopDefaults(installation: AgentInstallation) async throws {
    guard let controller = deepSeekDesktop else { throw BridgeMCPQueryError.unavailable }
    let defaults = try await controller.defaults(installation: installation)
    try await settings.set(defaults.modelID, for: .deepSeekHarnessDesktopDefaultModel)
    try await settings.set(defaults.effort, for: .deepSeekHarnessDesktopDefaultEffort)
  }

  func refreshAvailableDeepSeekDesktopDefaults() async throws {
    guard let controller = deepSeekDesktop,
      let installation = try? await deepSeekDesktopDefaultInstallation(),
      let status = try? await controller.status(installation: installation),
      status.connected && status.paired
    else { return }
    try await refreshDeepSeekDesktopDefaults(installation: installation)
  }

  func deepSeekDesktopDefaultInstallation() async throws -> AgentInstallation {
    let registry = try requiredAgentRegistry()
    let records = try await registry.installations(providerID: .deepSeekHarnessDesktop)
    let activeID = try await settings.string(for: .deepSeekHarnessDesktopActiveInstallationID)
    guard
      let record = ServiceDeepSeekHarnessInstallationSelection.desktopInstallation(
        in: records, activeID: activeID)
    else {
      throw BridgeMCPQueryError.unavailable
    }
    return try await registry.validateDesktopInstallation(installationID: record.id)
      .agentInstallation()
  }

  func setDeepSeekDesktopDefaults(
    model: String?, permissionMode: String?, effort: String?,
    updateEffort: Bool
  ) async throws -> (model: String?, permissionMode: String, effort: String?) {
    guard let controller = deepSeekDesktop else { throw BridgeMCPQueryError.unavailable }
    let installation = try await deepSeekDesktopDefaultInstallation()
    let descriptor = try ServiceAgentDefaultSettings.descriptor(
      for: .deepSeekHarnessDesktop)
    let validated = try Self.validatedAgentModel(model)
    let permission: String
    if let permissionMode {
      permission = try descriptor.normalizedPermission(permissionMode)
    } else {
      permission = try await descriptor.permissionMode(from: settings)
    }
    guard permission == ServicePermissionMode.full.rawValue else {
      throw BridgeMCPQueryError.agentPermissionUnsupported
    }
    let old = try await controller.defaults(installation: installation)
    let defaults = try await controller.setDefaults(
      modelID: validated,
      effort: updateEffort ? effort : old.effort, installation: installation)
    try await settings.set(defaults.modelID, for: descriptor.modelKey)
    try await settings.set(defaults.effort, for: descriptor.effortKey)
    try await settings.set(permission, for: descriptor.permissionKey)
    return (defaults.modelID, permission, defaults.effort)
  }
}

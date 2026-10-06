import BridgeAgentCore
import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

struct ServiceAgentSubmissionContext: Sendable {
  let policy: ServiceAgentProviderPolicy
  let registry: ServiceAgentRegistry
  let record: ServiceAgentInstallationRecord
  let defaults: ServiceAgentDefaultSettings
  let permission: ServicePermissionMode
  let supportsModelSelection: Bool
  let resolvedModel: String?
  let requestedEffort: String?
  let configuredEffort: String?
  let runtimeBinding: AgentRuntimeBinding?
  let preservesNativeSessionModel: Bool
}

extension BridgeServiceApplication {
  func resolveAgentSubmissionContext(
    submission: MCPServiceTaskSubmission, providerRaw: String,
    project: ServiceProjectRecord, workbenchPermissionMode: ServicePermissionMode?,
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceAgentSubmissionContext {
    let providerID = AgentProviderID(rawValue: providerRaw)
    guard let policy = ServiceAgentProviderPolicyRegistry.policy(for: providerID),
      policy.requiresInstallation
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    let (requestedModel, requestedEffort) = try Self.agentSubmissionOverrides(
      submission: submission, policy: policy)
    let registry = try requiredAgentRegistry()
    let selectable =
      try await registry.installations(providerID: providerID)
      .filter { $0.isSelectable || (providerID == .deepSeekHarness && $0.isEnabled) }
      .sorted { $0.id.rawValue < $1.id.rawValue }
    var record = try await selectAgentInstallation(
      providerID: providerID,
      requested: submission.installationID,
      selectable: selectable,
      deadline: deadline
    )
    let runtimeBinding = try await deepSeekSubmissionRuntimeBinding(
      submission: submission, record: record, project: project)
    if let runtimeBinding {
      record = try await registry.validateForRuntimeBinding(
        installationID: record.id,
        projectRoot: project.root.canonicalPath, runtimeBinding: runtimeBinding)
      if runtimeBinding.connectionMode == .nativeDesktop {
        guard submission.attachmentPaths?.isEmpty != false,
          submission.skillName == nil, submission.skillNames?.isEmpty != false
        else { throw BridgeMCPQueryError.contractRejected }
      }
    }
    let defaults: ServiceAgentDefaultSettings
    if providerID == .qoder {
      guard let distribution = try await qoderDistribution(for: record) else {
        throw BridgeMCPQueryError.contractRejected
      }
      defaults = try ServiceAgentDefaultSettings.descriptor(
        for: policy.providerID, distribution: distribution)
    } else {
      defaults = try ServiceAgentDefaultSettings.descriptor(
        for: policy.providerID,
        connectionMode: runtimeBinding?.connectionMode ?? .acp)
    }
    if runtimeBinding?.connectionMode == .nativeDesktop {
      try await refreshDeepSeekDesktopDefaults(installation: record.agentInstallation())
    }
    let configuredModel = try await settings.string(for: defaults.modelKey)
    let configuredEffort =
      policy.supportsEffortSelection
      ? try await settings.string(for: defaults.effortKey) : nil
    let permission = try await agentSubmissionPermission(
      submission: submission, policy: policy, defaults: defaults,
      workbenchPermissionMode: workbenchPermissionMode)
    let effectiveCapabilities = try Self.agentSubmissionCapabilities(
      submission: submission, policy: policy, record: record,
      permission: permission, requestedModel: requestedModel, requestedEffort: requestedEffort)
    let supportsModelSelection = effectiveCapabilities.contains(.modelSelection)
    let resolvedModel = try Self.validatedAgentModel(
      supportsModelSelection ? (requestedModel ?? configuredModel) : nil
    )
    return ServiceAgentSubmissionContext(
      policy: policy, registry: registry, record: record, defaults: defaults,
      permission: permission, supportsModelSelection: supportsModelSelection,
      resolvedModel: resolvedModel, requestedEffort: requestedEffort,
      configuredEffort: configuredEffort, runtimeBinding: runtimeBinding,
      preservesNativeSessionModel: runtimeBinding?.connectionMode == .nativeDesktop
        && submission.threadID != nil && submission.modelOverride != true)
  }

  private static func agentSubmissionOverrides(
    submission: MCPServiceTaskSubmission, policy: ServiceAgentProviderPolicy
  ) throws -> (model: String?, effort: String?) {
    guard submission.supervisorModel == nil && submission.supervisorEffort == nil else {
      throw BridgeMCPQueryError.contractRejected
    }
    guard
      policy.supportsSkillSelection
        || (submission.skillName == nil && submission.skillNames?.isEmpty != false)
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    guard policy.supportsSessionContinuation || submission.threadID == nil else {
      throw BridgeMCPQueryError.contractRejected
    }

    // Only an explicit user override replaces the persisted provider selection.
    let usesOverride = submission.modelOverride == true
    let requestedModel = usesOverride ? submission.executionModel : nil
    let requestedEffort = usesOverride ? submission.executionEffort : nil
    if !policy.supportsModelSelection && requestedModel != nil {
      throw BridgeMCPQueryError.contractRejected
    }
    if !policy.supportsEffortSelection && requestedEffort != nil {
      throw BridgeMCPQueryError.contractRejected
    }
    if let model = requestedModel {
      guard !model.isEmpty, model.utf8.count <= 256,
        model.rangeOfCharacter(from: .controlCharacters) == nil
      else { throw BridgeMCPQueryError.contractRejected }
    }
    return (requestedModel, requestedEffort)
  }

  private func agentSubmissionPermission(
    submission: MCPServiceTaskSubmission, policy: ServiceAgentProviderPolicy,
    defaults: ServiceAgentDefaultSettings,
    workbenchPermissionMode: ServicePermissionMode?
  ) async throws -> ServicePermissionMode {
    let defaultMode: ServicePermissionMode
    if let workbenchPermissionMode {
      defaultMode = workbenchPermissionMode
    } else {
      let configuredMode = try await defaults.permissionMode(from: settings)
      defaultMode = try Self.permissionMode(configuredMode)
    }
    let permission = try Self.permissionMode(
      workbenchPermissionMode == nil ? submission.permissionMode : nil,
      defaultMode: defaultMode
    )
    guard policy.supportsWorkspaceWrite || permission != .full else {
      throw BridgeMCPQueryError.contractRejected
    }
    guard permission != .full || policy.allowsNetworkAccess else {
      throw BridgeMCPQueryError.unavailable
    }
    return permission
  }

  private static func agentSubmissionCapabilities(
    submission: MCPServiceTaskSubmission, policy: ServiceAgentProviderPolicy,
    record: ServiceAgentInstallationRecord,
    permission: ServicePermissionMode, requestedModel: String?, requestedEffort: String?
  ) throws -> Set<AgentCapability> {
    let providerID = policy.providerID
    let effectiveCapabilities = policy.effectiveCapabilities(
      record.capabilities.effective
    )
    if permission == .readOnly, !effectiveCapabilities.contains(.readOnlyExecution) {
      throw BridgeMCPQueryError.agentPermissionUnsupported
    }
    let supportsModelSelection = effectiveCapabilities.contains(.modelSelection)
    let mutationIntent: AgentMutationIntent =
      permission == .full ? .workspaceWrite : .readOnly
    if providerID == .pi || providerID == .qoder,
      !effectiveCapabilities.isSuperset(of: mutationIntent.requiredCapabilities(for: providerID))
    {
      throw BridgeMCPQueryError.unavailable
    }
    if requestedModel != nil, !supportsModelSelection {
      throw BridgeMCPQueryError.unavailable
    }
    if policy.selectionsRequireObservedCapabilities {
      var requiredCapabilities = Set<AgentCapability>()
      if submission.threadID != nil { requiredCapabilities.insert(.sessionContinue) }
      if requestedModel != nil { requiredCapabilities.insert(.modelSelection) }
      if requestedEffort != nil { requiredCapabilities.insert(.effortSelection) }
      guard effectiveCapabilities.isSuperset(of: requiredCapabilities) else {
        throw BridgeMCPQueryError.unavailable
      }
    }
    return effectiveCapabilities
  }
}

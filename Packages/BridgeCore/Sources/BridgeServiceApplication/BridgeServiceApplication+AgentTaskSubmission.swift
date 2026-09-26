import BridgeAgentCore
import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  /// Explicit non-Codex submissions resolve against the user-registered agent
  /// installations. Provider-specific task constraints live in the shared
  /// service policy registry; adapter capabilities are checked by the runner.
  func prepareAgentSubmission(
    _ submission: MCPServiceTaskSubmission,
    providerRaw: String,
    project: ServiceProjectRecord,
    sourceClientID: String,
    source: ServiceTaskSource,
    workbenchPermissionMode: ServicePermissionMode?,
    deadline: ContinuousClock.Instant
  ) async throws -> PreparedTaskSubmission {
    let providerID = AgentProviderID(rawValue: providerRaw)
    guard let policy = ServiceAgentProviderPolicyRegistry.policy(for: providerID),
      policy.requiresInstallation
    else {
      throw BridgeMCPQueryError.contractRejected
    }
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
    // A remote MCP model can fill optional tool arguments from its own safety
    // preference. Only a submission explicitly marked as a user-requested
    // override may replace persisted provider defaults. The nil case keeps
    // older in-process callers source-compatible; the MCP parser normalizes a
    // missing marker to false.
    let registry = try requiredAgentRegistry()
    let selectable =
      try await registry.installations(providerID: providerID)
      .filter { $0.isSelectable }
      .sorted { $0.id.rawValue < $1.id.rawValue }
    let record = try await selectAgentInstallation(
      providerID: providerID,
      requested: submission.installationID,
      selectable: selectable,
      deadline: deadline
    )
    let defaults: ServiceAgentDefaultSettings
    if providerID == .qoder {
      guard let distribution = try await qoderDistribution(for: record) else {
        throw BridgeMCPQueryError.contractRejected
      }
      defaults = try ServiceAgentDefaultSettings.descriptor(
        for: policy.providerID, distribution: distribution)
    } else {
      defaults = try ServiceAgentDefaultSettings.descriptor(for: policy.providerID)
    }
    let configuredModel = try await settings.string(for: defaults.modelKey)
    let configuredEffort =
      policy.supportsEffortSelection
      ? try await settings.string(for: defaults.effortKey) : nil
    let configuredMode = try await defaults.permissionMode(from: settings)
    let providerDefaultMode: ServicePermissionMode =
      configuredMode == defaults.readMode ? .readOnly : .workspaceWrite
    let requestedPermissionMode = try Self.permissionModeRequest(
      submission.permissionMode,
      override: submission.permissionModeOverride,
      requirePermissionModeOverride: workbenchPermissionMode != nil
    )
    if !policy.supportsWorkspaceWrite,
      requestedPermissionMode == ServicePermissionMode.workspaceWrite.rawValue
    {
      throw BridgeMCPQueryError.contractRejected
    }
    let permission = try Self.permissionMode(
      requestedPermissionMode,
      project: project,
      defaultMode: workbenchPermissionMode ?? providerDefaultMode
    )
    guard policy.supportsWorkspaceWrite || permission != .workspaceWrite else {
      throw BridgeMCPQueryError.contractRejected
    }
    guard !submission.networkAccess || policy.allowsNetworkAccess else {
      // Provider policies never persist a requested network grant as though
      // the Bridge enforced it when the adapter has no task-level sandbox.
      throw BridgeMCPQueryError.unavailable
    }
    let effectiveCapabilities = policy.effectiveCapabilities(
      record.capabilities.effective,
      projectAllowsWorkspaceWrite: project.accessPolicy.write != .denied
    )
    let supportsModelSelection = effectiveCapabilities.contains(.modelSelection)
    let mutationIntent: AgentMutationIntent =
      permission == .workspaceWrite ? .workspaceWrite : .readOnly
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
    let resolvedModel = try Self.validatedAgentModel(
      supportsModelSelection ? (requestedModel ?? configuredModel) : nil
    )
    var previousBridgeTask: ServiceTaskRecord?
    if policy.supportsSessionContinuation, let requestedSessionID = submission.threadID {
      let previous = try await tasks.task(
        providerSessionID: requestedSessionID,
        providerID: providerID.rawValue,
        installationID: record.id.rawValue,
        projectID: project.id
      )
      previousBridgeTask = previous
      if let previous {
        guard previous.state.status.isTerminal else {
          throw BridgeMCPQueryError.invalidTaskState
        }
      } else {
        guard providerID == .pi || providerID == .qoder else {
          throw BridgeMCPQueryError.taskNotFound
        }
        let (directory, installation, verifiedRecord) =
          try await registry
          .nativeSessionDirectoryManager(installationID: record.id)
        let scope = try await nativeSessionScope(project: project, installation: verifiedRecord)
        let active = try await tasks.nonterminalTasks().contains { task in
          task.projectID == project.id && task.providerID == providerID.rawValue
            && task.installationID == record.id.rawValue
            && (task.state.providerSessionID ?? task.requestedThreadID) == requestedSessionID
        }
        guard !active,
          try await directory.isIndexedNativeSession(
            sessionID: requestedSessionID, scope: scope, installation: installation)
        else { throw BridgeMCPQueryError.taskNotFound }
      }
    }
    var attachmentSourceTask: ServiceTaskRecord?
    if let sourceTaskID = submission.attachmentSourceTaskID {
      guard source == .macOSApp, submission.threadID == nil, sourceTaskID.utf8.count <= 128,
        let sourceTask = try await tasks.task(id: TaskID(rawValue: sourceTaskID)),
        sourceTask.state.status.isTerminal, sourceTask.projectID == project.id,
        sourceTask.providerID == providerID.rawValue,
        sourceTask.installationID == record.id.rawValue
      else { throw BridgeMCPQueryError.contractRejected }
      attachmentSourceTask = sourceTask
    }
    let modelCatalog: [AgentModelDescriptor]?
    if supportsModelSelection {
      modelCatalog = try? await serviceAgentModelCatalog(
        registry: registry,
        installationID: record.id,
        projectRoot: project.root.canonicalPath,
        selectedModelID: resolvedModel
      )
    } else {
      modelCatalog = nil
    }
    let selectedDescriptor: AgentModelDescriptor?
    if let modelCatalog {
      if let resolvedModel {
        selectedDescriptor =
          modelCatalog.first(where: { $0.id == resolvedModel })
          ?? Self.legacyDeepSeekDescriptor(
            providerID: policy.providerID,
            modelID: resolvedModel,
            catalog: modelCatalog
          )
      } else if providerID == .qoder {
        selectedDescriptor = modelCatalog.first(where: { $0.isDefaultModel == true })
      } else {
        selectedDescriptor = modelCatalog.first(where: {
          !$0.supportedReasoningEfforts.isEmpty
        })
      }
    } else {
      selectedDescriptor = nil
    }
    if defaults.requiresKnownModel, resolvedModel != nil, selectedDescriptor == nil {
      throw BridgeMCPQueryError.unavailable
    }
    let executionEffort: String
    if let requestedEffort {
      guard modelCatalog != nil else { throw BridgeMCPQueryError.unavailable }
      guard selectedDescriptor?.supportedReasoningEfforts.contains(requestedEffort) == true else {
        throw BridgeMCPQueryError.contractRejected
      }
      executionEffort = requestedEffort
    } else if let configuredEffort,
      selectedDescriptor?.supportedReasoningEfforts.contains(configuredEffort) == true
    {
      executionEffort = configuredEffort
    } else {
      executionEffort = serviceDefaultProviderExecutionEffort
    }
    let selectedSkills = try await selectedSkillSnapshots(
      for: submission,
      project: project,
      deadline: deadline,
      previousTask: previousBridgeTask ?? attachmentSourceTask
    )
    let prompt = try await taskPrompt(
      for: submission,
      deadline: deadline,
      selectedSkills: selectedSkills
    )
    let attachments: [AgentImageAttachment]
    if let sourceTask = attachmentSourceTask {
      let originalAttachments = try await tasks.taskAttachments(taskID: sourceTask.id)
      guard let confirmedSourceTask = try await tasks.task(id: sourceTask.id),
        confirmedSourceTask.state.status.isTerminal,
        confirmedSourceTask.projectID == project.id,
        confirmedSourceTask.providerID == providerID.rawValue,
        confirmedSourceTask.installationID == record.id.rawValue
      else {
        throw BridgeMCPQueryError.contractRejected
      }
      attachments = try ServiceAgentAttachments.captureForRestart(
        relativePaths: submission.attachmentPaths ?? [],
        originalAttachments: originalAttachments,
        project: project,
        model: selectedDescriptor
      )
    } else {
      attachments = try ServiceAgentAttachments.capture(
        relativePaths: submission.attachmentPaths ?? [],
        project: project,
        model: selectedDescriptor
      )
    }
    let executionModel =
      supportsModelSelection
      ? selectedDescriptor?.id ?? resolvedModel ?? serviceDefaultProviderExecutionModel
      : serviceDefaultProviderExecutionModel
    return PreparedTaskSubmission(
      projectID: project.id,
      request: ServiceTaskRequest(
        projectID: project.id,
        source: source,
        sourceClientID: source == .mcpClient ? sourceClientID : "",
        clientRequestID: submission.clientRequestID,
        prompt: prompt,
        requestedThreadID: submission.threadID,
        providerID: providerID.rawValue,
        installationID: record.id.rawValue,
        selectionMode: .explicit,
        executionModel: executionModel,
        executionEffort: executionEffort,
        permissionMode: permission,
        networkAllowed: submission.networkAccess,
        accessMode: .requestApproval,
        queueIfBusy: submission.queueIfBusy == true,
        attachments: attachments,
        selectedSkills: selectedSkills
      )
    )
  }

  private static func legacyDeepSeekDescriptor(
    providerID: AgentProviderID,
    modelID: String,
    catalog: [AgentModelDescriptor]
  ) -> AgentModelDescriptor? {
    let prefix = "opencode-go/"
    guard providerID == .deepSeekHarness, modelID.hasPrefix(prefix) else { return nil }
    let wireModelID = String(modelID.dropFirst(prefix.count))
    return catalog.first(where: { $0.id == wireModelID })
  }

  static func validatedAgentModel(_ model: String?) throws -> String? {
    guard let model else { return nil }
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 256,
      !trimmed.contains("\0"),
      trimmed.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    return trimmed
  }

  static func selectAgentInstallation(
    requested: String?,
    from selectable: [ServiceAgentInstallationRecord]
  ) throws -> ServiceAgentInstallationRecord {
    if let requested {
      guard let record = selectable.first(where: { $0.id.rawValue == requested }) else {
        throw BridgeMCPQueryError.unavailable
      }
      return record
    }
    guard let record = selectable.first else {
      throw BridgeMCPQueryError.unavailable
    }
    return record
  }
}

import BridgeAgentCore
import Foundation

extension OpenCodeACPProvider {
  public func models(
    installation: AgentInstallation,
    projectRoot: String?
  ) async throws -> [AgentModelDescriptor] {
    try await models(
      installation: installation,
      projectRoot: projectRoot,
      selectedModelID: nil
    )
  }

  public func models(
    installation: AgentInstallation,
    projectRoot: String?,
    selectedModelID: String?
  ) async throws -> [AgentModelDescriptor] {
    guard installation.providerID == .openCode else {
      throw AgentRuntimeError.providerUnavailable(installation.providerID)
    }
    let probeRoot = try makeProbeRoot(projectRoot)
    let runDirectory: String
    do {
      runDirectory = try makeRunDirectory(prefix: "models-run")
    } catch {
      cleanup(runDirectory: nil, probeRoot: probeRoot)
      throw error
    }
    var client: OpenCodeACPClient?
    do {
      let launch = try configuration.launchBuilder.make(
        installation: installation,
        projectRoot: probeRoot.path,
        runDirectory: runDirectory,
        networkAllowed: false,
        sourceEnvironment: configuration.sourceEnvironment
      )
      let connected = makeClient(transport: try configuration.transportFactory(launch))
      client = connected
      let initialization = try await connected.initialize()
      _ = try validate(initialization)
      let session = try await connected.newSession(cwd: launch.process.workingDirectory)
      if let selectedModelID {
        let model = try Self.resolveModel(selectedModelID, from: session)
        let options = try await connected.setSessionConfigOption(
          sessionID: session.id,
          configID: "model",
          value: model
        )
        let models = try Self.modelDescriptors(
          from: options,
          selectedModelID: model,
          defaultModelID: Self.availableCurrentModelID(in: session)
        )
        await connected.shutdown()
        cleanup(runDirectory: launch.runDirectory, probeRoot: probeRoot)
        return models
      }

      let modelOption = try Self.modelOption(from: session.configOptions)
      guard !modelOption.values.isEmpty else {
        throw AgentRuntimeError.capabilityUnavailable(.modelSelection)
      }
      let modelIDs = modelOption.values.map(\.value)
      let currentModel = Self.availableCurrentModelID(in: session)
      if modelIDs.count == 1, currentModel == nil {
        let models = try Self.modelDescriptors(
          from: session.configOptions,
          selectedModelID: nil,
          defaultModelID: currentModel
        )
        await connected.shutdown()
        cleanup(runDirectory: launch.runDirectory, probeRoot: probeRoot)
        return models
      }

      var models = try Self.baseModelDescriptors(from: modelOption, defaultModelID: currentModel)
      for modelID in modelIDs {
        do {
          let options = try await connected.setSessionConfigOption(
            sessionID: session.id,
            configID: "model",
            value: modelID
          )
          let resolved = try Self.modelDescriptors(
            from: options,
            selectedModelID: modelID,
            defaultModelID: currentModel
          )
          guard let descriptor = resolved.first(where: { $0.id == modelID }) else { continue }
          models = Self.replacingModel(descriptor, in: models)
        } catch {
          models = Self.markReasoningUnavailable(for: modelID, in: models)
        }
      }
      await connected.shutdown()
      cleanup(runDirectory: launch.runDirectory, probeRoot: probeRoot)
      return models
    } catch {
      await client?.shutdown()
      cleanup(runDirectory: runDirectory, probeRoot: probeRoot)
      throw Self.runtimeError(for: error)
    }
  }

  func capabilities(
    _ initialization: OpenCodeACPInitialization
  ) -> AgentCapabilitySnapshot {
    var supported: Set<AgentCapability> = [
      .sessionCreate,
      .interrupt,
      .steer,
      .textDelta,
      .reasoningDelta,
      .toolLifecycle,
      .plan,
      .usage,
      .workspaceRead,
      .workspaceWriteInPlace,
      .oneShotApproval,
      .profileSelection,
      .modelSelection,
    ]
    if initialization.supportsLoadSession || initialization.supportsResumeSession {
      supported.insert(.sessionContinue)
    }
    return AgentCapabilitySnapshot(
      advertised: supported,
      observed: supported,
      enforced: supported
    )
  }

  static func modelDescriptors(
    from options: [OpenCodeACPConfigOption],
    selectedModelID: String? = nil,
    defaultModelID: String? = nil
  ) throws -> [AgentModelDescriptor] {
    guard let option = options.first(where: { $0.id == "model" }) else {
      throw AgentRuntimeError.capabilityUnavailable(.modelSelection)
    }
    let selected = selectedModelID ?? option.currentValue
    let defaultModel = defaultModelID ?? Self.availableDefaultModelID(in: option)
    let effort = options.first(where: { $0.id == "effort" })
    return try option.values.map { value in
      try AgentModelDescriptor(
        id: value.value,
        displayName: value.name,
        supportedReasoningEfforts: value.value == selected
          ? effort?.values.map(\.value) ?? [] : [],
        defaultReasoningEffort: value.value == selected ? effort?.currentValue : nil,
        reasoningCapabilitiesAvailable: value.value == selected,
        isDefaultModel: defaultModel.map { $0 == value.value }
      )
    }
  }

  private static func modelOption(
    from options: [OpenCodeACPConfigOption]
  ) throws -> OpenCodeACPConfigOption {
    guard let option = options.first(where: { $0.id == "model" }) else {
      throw AgentRuntimeError.capabilityUnavailable(.modelSelection)
    }
    return option
  }

  private static func baseModelDescriptors(
    from option: OpenCodeACPConfigOption,
    defaultModelID: String?
  ) throws -> [AgentModelDescriptor] {
    try option.values.map { value in
      try AgentModelDescriptor(
        id: value.value,
        displayName: value.name,
        reasoningCapabilitiesAvailable: false,
        isDefaultModel: defaultModelID.map { $0 == value.value }
      )
    }
  }

  private static func replacingModel(
    _ descriptor: AgentModelDescriptor,
    in models: [AgentModelDescriptor]
  ) -> [AgentModelDescriptor] {
    models.map { $0.id == descriptor.id ? descriptor : $0 }
  }

  private static func markReasoningUnavailable(
    for modelID: String,
    in models: [AgentModelDescriptor]
  ) -> [AgentModelDescriptor] {
    models.compactMap {
      guard $0.id == modelID else { return $0 }
      return try? AgentModelDescriptor(
        id: $0.id,
        displayName: $0.displayName,
        reasoningCapabilitiesAvailable: false,
        isDefaultModel: $0.isDefaultModel
      )
    }
  }

  static func modelDescriptors(from session: OpenCodeACPSession) throws
    -> [AgentModelDescriptor]
  {
    try modelDescriptors(from: session.configOptions)
  }

  private static func currentModelID(in session: OpenCodeACPSession) -> String? {
    session.configOptions.first(where: { $0.id == "model" })?.currentValue
  }

  static func availableCurrentModelID(in session: OpenCodeACPSession) -> String? {
    guard let option = session.configOptions.first(where: { $0.id == "model" }),
      let currentValue = option.currentValue,
      option.values.contains(where: { $0.value == currentValue })
    else { return nil }
    return currentValue
  }

  private static func availableDefaultModelID(
    in option: OpenCodeACPConfigOption
  ) -> String? {
    guard let currentValue = option.currentValue,
      option.values.contains(where: { $0.value == currentValue })
    else { return nil }
    return currentValue
  }

  static func modeValue(
    for mutationIntent: AgentMutationIntent,
    in session: OpenCodeACPSession
  ) throws -> String {
    let expected = mutationIntent == .readOnly ? "plan" : "build"
    guard let option = session.configOptions.first(where: { $0.id == "mode" }),
      option.values.contains(where: { $0.value == expected })
    else {
      throw AgentRuntimeError.capabilityUnavailable(
        mutationIntent == .readOnly ? .workspaceRead : .workspaceWriteInPlace
      )
    }
    return expected
  }

  static func resolveModel(
    _ requested: String,
    from session: OpenCodeACPSession
  ) throws -> String {
    let models = try modelDescriptors(from: session)
    if models.contains(where: { $0.id == requested }) { return requested }
    throw AgentRuntimeError.modelUnavailable(requested)
  }

  func require(
    _ required: Set<AgentCapability>,
    from snapshot: AgentCapabilitySnapshot
  ) throws {
    guard
      let missing = required.subtracting(snapshot.effective)
        .sorted(by: { $0.rawValue < $1.rawValue })
        .first
    else { return }
    throw AgentRuntimeError.capabilityUnavailable(missing)
  }
}

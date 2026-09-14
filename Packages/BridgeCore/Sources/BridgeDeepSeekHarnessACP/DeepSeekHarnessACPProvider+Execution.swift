import BridgeAgentCore
import Foundation

extension DeepSeekHarnessACPProvider {
  public func start(
    _ request: AgentExecutionRequest,
    installation: AgentInstallation
  ) async throws -> AgentExecutionHandle {
    try validate(request: request, installation: installation)
    let runDirectory = try makeRunDirectory(prefix: "run")
    var client: DeepSeekHarnessACPClient?
    do {
      let persistentStateDirectory = try makePersistentStateDirectory(
        installation: installation,
        request: request
      )
      let sourceEnvironment = try await configuration.runtimeEnvironment(for: installation)
      let launch = try configuration.launchBuilder.make(
        installation: installation,
        projectRoot: request.projectRoot,
        runDirectory: runDirectory,
        persistentStateDirectory: persistentStateDirectory,
        modelID: request.model,
        reasoningEffort: request.effort,
        mutationIntent: request.mutationIntent,
        networkAllowed: request.networkAccessRequested,
        sourceEnvironment: sourceEnvironment
      )
      let connected = makeClient(transport: try configuration.transportFactory(launch))
      client = connected
      let initialization = try await connected.initialize()
      try validate(initialization)
      let capabilities = Self.capabilities(
        executablePath: launch.resolvedExecutablePath,
        initialization: initialization,
        persistenceAvailable: configuration.persistentStateBaseDirectory != nil
      )
      try require(request.requiredCapabilities, from: capabilities)
      let servers = try await configuration.mcpServersProvider()
      let mcpServers = try DeepSeekHarnessACPMCP.parameters(
        servers: servers, initialization: initialization,
        networkAllowed: request.networkAccessRequested
      )
      let session: DeepSeekHarnessACPSession
      if let requestedSessionID = request.requestedSessionID {
        guard persistentStateDirectory != nil,
          DeepSeekHarnessACPModernLaunch.isModernEntry(launch.resolvedExecutablePath),
          initialization.supportsResumeSession
        else {
          throw AgentRuntimeError.capabilityUnavailable(.sessionContinue)
        }
        session = try await connected.resumeSession(
          id: requestedSessionID,
          cwd: request.projectRoot, mcpServers: mcpServers
        )
      } else {
        session = try await connected.newSession(cwd: request.projectRoot, mcpServers: mcpServers)
      }
      try await applyRequestedSelection(
        request: request,
        session: session,
        client: connected
      )
      let binding = try AgentBinding(
        providerID: .deepSeekHarness,
        installationID: installation.id,
        providerSessionID: session.id,
        providerRunID: UUID().uuidString.lowercased()
      )
      let normalizer = DeepSeekHarnessACPEventNormalizer(
        taskID: request.taskID,
        binding: binding,
        projectRoot: request.projectRoot
      )
      let initialSequence = await connected.eventSequence
      let execution = DeepSeekHarnessACPExecution(
        client: connected,
        normalizer: normalizer,
        sessionID: session.id,
        prompt: request.prompt,
        initialClientEventSequence: initialSequence,
        inactivityTimeout: configuration.inactivityTimeout,
        eventBufferLimit: configuration.eventBufferLimit,
        requiresExecutionEvidence: !DeepSeekHarnessACPModernLaunch.isModernEntry(
          launch.resolvedExecutablePath),
        cleanup: {
          DeepSeekHarnessACPLaunchBuilder.removeRunDirectory(launch.runDirectory)
        }
      )
      await execution.start()
      return AgentExecutionHandle(
        taskID: request.taskID,
        binding: binding,
        capabilities: capabilities,
        events: execution.events,
        control: AgentExecutionControl(
          interrupt: { try await execution.interrupt() },
          shutdown: { await execution.shutdown() },
          steer: { text in try await execution.steer(text: text) },
          interruptAndSteer: { text in
            try await execution.interruptCurrentThenSteer(text: text)
          },
          resolveApproval: { approvalID, optionID in
            try await execution.resolveApproval(
              approvalID: approvalID,
              optionID: optionID
            )
          }
        )
      )
    } catch {
      await client?.shutdown()
      DeepSeekHarnessACPLaunchBuilder.removeRunDirectory(runDirectory)
      throw Self.runtimeError(for: error)
    }
  }

  private func validate(
    request: AgentExecutionRequest,
    installation: AgentInstallation
  ) throws {
    guard installation.providerID == .deepSeekHarness else {
      throw AgentRuntimeError.providerUnavailable(installation.providerID)
    }
    guard request.mutationIntent == .readOnly || request.mutationIntent == .workspaceWrite else {
      throw AgentRuntimeError.invalidRequest("request.mutationIntent")
    }
    guard
      request.workspaceStrategy == .sharedProject
        || request.workspaceStrategy == .exclusiveProject
    else {
      throw AgentRuntimeError.invalidRequest("request.workspaceStrategy")
    }
    _ = try configuration.launchBuilder.profile.resolvedSelection(
      for: installation,
      modelID: request.model,
      reasoningEffort: request.effort
    )
    guard
      request.profileID == nil || request.profileID == DeepSeekHarnessACPProfiles.controlledReadOnly
    else {
      throw AgentRuntimeError.capabilityUnavailable(.profileSelection)
    }
  }

  private func require(
    _ required: Set<AgentCapability>,
    from snapshot: AgentCapabilitySnapshot
  ) throws {
    guard
      let missing = required.subtracting(snapshot.effective)
        .sorted(by: { $0.rawValue < $1.rawValue }).first
    else { return }
    throw AgentRuntimeError.capabilityUnavailable(missing)
  }
}

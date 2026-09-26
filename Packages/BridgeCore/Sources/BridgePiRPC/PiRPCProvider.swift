import BridgeAgentCore
import BridgeSecurity
import Foundation

public struct PiRPCProviderConfiguration: Sendable {
  public let runtimeBaseDirectory: String
  public let sourceEnvironment: [String: String]
  public let extensionDirectory: String?
  public let requestTimeout: Duration
  public let mcpServersProvider: @Sendable () async throws -> [AgentMCPServerConfiguration]
  public let transportFactory: @Sendable (PiRPCLaunch) throws -> any PiRPCTransport

  public init(
    runtimeBaseDirectory: String,
    sourceEnvironment: [String: String] = ToolDiscoveryEnvironment.current(),
    extensionDirectory: String? = nil,
    requestTimeout: Duration = .seconds(30),
    mcpServersProvider: @escaping @Sendable () async throws -> [AgentMCPServerConfiguration] = {
      []
    },
    transportFactory: @escaping @Sendable (PiRPCLaunch) throws -> any PiRPCTransport = {
      try PiRPCProcessTransport(launch: $0)
    }
  ) {
    self.runtimeBaseDirectory = runtimeBaseDirectory
    self.sourceEnvironment = sourceEnvironment
    self.extensionDirectory = extensionDirectory
    self.requestTimeout = requestTimeout
    self.mcpServersProvider = mcpServersProvider
    self.transportFactory = transportFactory
  }
}

public struct PiRPCProvider: AgentProvider, Sendable {
  public let descriptor: AgentProviderDescriptor
  public let nativePermissionPolicyManager: (any AgentNativePermissionPolicyManaging)?
  let configuration: PiRPCProviderConfiguration

  public init(configuration: PiRPCProviderConfiguration) throws {
    self.configuration = configuration
    nativePermissionPolicyManager = PiNativePermissionPolicyManager(
      runtimeBaseDirectory: configuration.runtimeBaseDirectory)
    descriptor = try AgentProviderDescriptor(providerID: .pi, displayName: "Pi", adapterRevision: 1)
  }

  public func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
    var client: PiRPCClient?
    do {
      let profile = try PiRuntimeProfile.make(
        installation: request.installation, request: nil, configuration: configuration)
      let version = try await PiVersionProbe.read(profile.launch)
      let connected = try makeClient(profile)
      client = connected
      _ = try await initialize(connected, profile: profile)
      let modelCatalog = try await availableModels(connected)
      guard !modelCatalog.isEmpty else {
        let installation = try AgentInstallation(
          id: request.installation.id, providerID: .pi,
          executablePath: request.installation.executablePath, version: version,
          protocolRevision: "pi-rpc-v1", artifacts: profile.artifacts)
        await connected.shutdown()
        return AgentProbeResult(
          installation: installation, available: false, capabilities: .empty,
          unavailableReason: Self.modelCatalogUnavailableReason)
      }
      let usageAvailable = await Self.supportsSessionStats(connected)
      let installation = try AgentInstallation(
        id: request.installation.id, providerID: .pi,
        executablePath: request.installation.executablePath, version: version,
        protocolRevision: "pi-rpc-v1", artifacts: profile.artifacts)
      await connected.shutdown()
      return AgentProbeResult(
        installation: installation, available: true,
        capabilities: Self.capabilities(usageAvailable: usageAvailable))
    } catch {
      await client?.shutdown()
      return AgentProbeResult(
        installation: request.installation, available: false, capabilities: .empty,
        unavailableReason: Self.failureDescription(error))
    }
  }

  public func start(_ request: AgentExecutionRequest, installation: AgentInstallation)
    async throws -> AgentExecutionHandle
  {
    guard
      request.workspaceStrategy == .sharedProject || request.workspaceStrategy == .exclusiveProject,
      request.profileID == nil || request.profileID?.rawValue == "pi-managed",
      Self.supportedCapabilities.isSuperset(of: request.requiredCapabilities)
    else { throw AgentRuntimeError.invalidRequest("pi.execution_mode") }
    guard let nativePermissionPolicyManager else {
      throw AgentNativePermissionPolicyError.unavailable
    }
    let permissions = try await nativePermissionPolicyManager.snapshot(installation: installation)
    let mcpServers = try await configuration.mcpServersProvider()
    let profile = try PiRuntimeProfile.make(
      installation: installation, request: request, configuration: configuration,
      nativePermissionRules: permissions.rules, mcpServers: mcpServers)
    var skillStageTransferred = false
    defer {
      if !skillStageTransferred { profile.selectedSkillStage?.cleanup() }
    }
    try validateArtifacts(profile.artifacts, registered: installation.artifacts)
    let client = try makeClient(profile)
    do {
      var state = try await initialize(client, profile: profile)
      let modelCatalog = try await availableModels(client)
      guard !modelCatalog.isEmpty else {
        throw AgentRuntimeError.modelUnavailable("pi.no_configured_model")
      }
      if let model = request.model { try await selectModel(model, client: client) }
      if let effort = request.effort { try await selectEffort(effort, client: client) }
      let usageAvailable = await Self.supportsSessionStats(client)
      let capabilities = Self.capabilities(usageAvailable: usageAvailable)
      guard capabilities.supports(request.requiredCapabilities) else {
        throw AgentRuntimeError.invalidRequest("pi.required_capability")
      }
      state = try await client.request("get_state").data ?? state
      let images = try Self.imageBlocks(
        request.attachments, models: modelCatalog, state: state, projectRoot: request.projectRoot)
      guard let sessionID = state["sessionId"]?.stringValue, sessionID == profile.sessionID,
        let sessionFile = state["sessionFile"]?.stringValue, let store = profile.store
      else { throw AgentRuntimeError.sessionMismatch }
      try store.save(
        PiSessionBinding(
          projectID: request.projectID.rawValue,
          projectRoot: request.projectRoot, installationID: installation.id.rawValue,
          sessionID: sessionID, sessionFile: sessionFile))
      let binding = try AgentBinding(
        providerID: .pi, installationID: installation.id,
        providerSessionID: sessionID, providerRunID: UUID().uuidString.lowercased())
      let execution = PiRPCExecution(
        client: client, request: request, binding: binding,
        nonce: profile.nonce, initialSequence: await client.eventSequence,
        usageEnabled: usageAvailable, initialImages: images,
        selectedSkillStage: profile.selectedSkillStage)
      skillStageTransferred = true
      await execution.start()
      return AgentExecutionHandle(
        taskID: request.taskID, binding: binding,
        capabilities: capabilities, events: execution.events,
        control: AgentExecutionControl(
          interrupt: { try await execution.interrupt() },
          shutdown: { await execution.shutdown() },
          steer: { try await execution.steer($0) },
          interruptAndSteer: { try await execution.interruptAndSteer($0) },
          resolveApproval: { try await execution.resolveApproval($0, optionID: $1) },
          resolveUserInput: { try await execution.resolveUserInput($0, response: $1) }))
    } catch {
      await client.shutdown()
      throw error
    }
  }

  func makeClient(_ profile: PiRuntimeProfile) throws -> PiRPCClient {
    PiRPCClient(
      transport: try configuration.transportFactory(profile.launch),
      requestTimeout: configuration.requestTimeout)
  }

  func initialize(_ client: PiRPCClient, profile: PiRuntimeProfile) async throws -> PiJSONValue {
    let state = try await client.request("get_state").data
    guard let state, state["isStreaming"]?.boolValue == false,
      state["isCompacting"]?.boolValue == false, state["pendingMessageCount"]?.integerValue == 0
    else { throw PiRPCError.incompatibleRuntime }
    _ = try await client.request("get_available_thinking_levels")
    _ = try await client.request("set_follow_up_mode", fields: ["mode": .string("one-at-a-time")])
    guard let status = await client.status("codex-bridge.pi"),
      let bytes = status.data(using: .utf8),
      let handshake = try? JSONDecoder().decode(PiJSONValue.self, from: bytes),
      handshake["revision"]?.integerValue == 1,
      handshake["nonce"]?.stringValue == profile.nonce,
      validHandshakeTools(
        handshake["tools"], expected: profile.tools,
        mcpToolCount: handshake["mcp"]?["toolCount"]?.integerValue),
      handshake["capabilities"]?.arrayValue == [
        PiJSONValue.string("plan"), PiJSONValue.string("user_input"),
        PiJSONValue.string("mcp_client"), PiJSONValue.string("subagents"),
      ],
      validMCPState(handshake["mcp"], expected: profile.mcpServerIDs)
    else { throw PiRPCError.incompatibleRuntime }
    if !profile.mcpServerIDs.isEmpty,
      handshake["mcp"]?["failedServerIDs"]?.arrayValue?.isEmpty != true
    {
      throw PiRPCError.invalidArgument("pi.mcp_server_unavailable")
    }
    return state
  }

  func availableModels(_ client: PiRPCClient) async throws -> [PiJSONValue] {
    let response: PiRPCReply
    do { response = try await client.request("get_available_models") } catch PiRPCError.remote(
      command: "get_available_models", message: _)
    {
      throw AgentRuntimeError.modelUnavailable("pi.model_catalog_unavailable")
    }
    guard let values = response.data?["models"]?.arrayValue, values.count <= 4_096 else {
      throw PiRPCError.invalidRecord
    }
    return values
  }

  private func validHandshakeTools(
    _ value: PiJSONValue?, expected: [String], mcpToolCount: Int?
  ) -> Bool {
    guard let values = value?.arrayValue, let mcpToolCount,
      mcpToolCount >= 0, mcpToolCount <= 128,
      values.count == expected.count + mcpToolCount,
      values.prefix(expected.count).compactMap(\.stringValue) == expected,
      Set(values.compactMap(\.stringValue)).count == values.count,
      values.count == values.compactMap(\.stringValue).count
    else { return false }
    return values.dropFirst(expected.count).allSatisfy { value in
      value.stringValue.map {
        $0.range(
          of: #"^bridge_mcp_[a-f0-9]{12}_[a-z0-9_-]{1,28}_[a-f0-9]{10}$"#,
          options: .regularExpression) != nil
      } == true
    }
  }

  private func validMCPState(_ value: PiJSONValue?, expected: [String]) -> Bool {
    guard let value, let connected = value["connectedServerIDs"]?.arrayValue,
      let failed = value["failedServerIDs"]?.arrayValue,
      let toolCount = value["toolCount"]?.integerValue,
      toolCount >= 0, toolCount <= 128
    else { return false }
    let connectedIDs = connected.compactMap(\.stringValue)
    let failedIDs = failed.compactMap(\.stringValue)
    return connectedIDs.count == connected.count && failedIDs.count == failed.count
      && Set(connectedIDs).count == connectedIDs.count && Set(failedIDs).count == failedIDs.count
      && Set(connectedIDs).isDisjoint(with: failedIDs)
      && Set(connectedIDs + failedIDs) == Set(expected)
  }

  static func capabilities(usageAvailable: Bool) -> AgentCapabilitySnapshot {
    var observed = supportedCapabilities
    if !usageAvailable { observed.remove(.usage) }
    return AgentCapabilitySnapshot(
      advertised: supportedCapabilities,
      observed: observed, enforced: observed)
  }

  private static func imageBlocks(
    _ attachments: [AgentImageAttachment], models: [PiJSONValue], state: PiJSONValue,
    projectRoot: String
  ) throws -> [PiJSONValue] {
    guard !attachments.isEmpty else { return [] }
    guard let provider = state["model"]?["provider"]?.stringValue,
      let modelID = state["model"]?["id"]?.stringValue,
      let selected = models.first(where: {
        $0["provider"]?.stringValue == provider && $0["id"]?.stringValue == modelID
      }),
      selected["input"]?.arrayValue?.contains(.string("image")) == true
    else { throw AgentRuntimeError.invalidRequest("pi.model_image_input_unsupported") }
    return try attachments.map { attachment in
      let verified = try SecureProjectImageReader.read(
        attachment, projectRoot: projectRoot)
      return .object([
        "type": .string("image"), "data": .string(verified.data.base64EncodedString()),
        "mimeType": .string(verified.attachment.mimeType),
      ])
    }
  }

  private func validateArtifacts(
    _ current: [AgentInstallationArtifact],
    registered: [AgentInstallationArtifact]
  ) throws {
    guard !registered.isEmpty else { return }
    let currentByRole = Dictionary(uniqueKeysWithValues: current.map { ($0.role, $0) })
    let registeredByRole = Dictionary(uniqueKeysWithValues: registered.map { ($0.role, $0) })
    guard currentByRole.count == current.count, registeredByRole.count == registered.count,
      currentByRole.count == registeredByRole.count,
      currentByRole.allSatisfy({ role, artifact in
        guard let expected = registeredByRole[role] else { return false }
        return artifact.canonicalPath == expected.canonicalPath
          && artifact.sha256 == expected.sha256
      })
    else { throw AgentRuntimeError.invalidRequest("pi.installation_artifact_changed") }
  }

  static func supportsSessionStats(_ client: PiRPCClient) async -> Bool {
    do {
      let stats = try await client.request("get_session_stats", timeout: .seconds(10))
      return PiUsageNormalizer.supports(stats.data)
    } catch { return false }
  }

  private static let supportedCapabilities: Set<AgentCapability> = [
    .sessionCreate, .sessionContinue, .interrupt, .steer, .steerInterruptAndContinue,
    .textDelta, .reasoningDelta, .toolLifecycle, .oneShotApproval, .sessionRuleApproval,
    .structuredApprovalPayload, .workspaceRead, .workspaceWriteInPlace, .plan, .usage,
    .modelSelection, .effortSelection, .skills, .readOnlyExecution, .structuredUserInput,
    .mcpClient, .subagents, .childRuns,
  ]

  private static let modelCatalogUnavailableReason =
    "Pi 已安装并可连接，但当前账号没有可用模型。请在本机运行 pi 并执行 /login，或配置至少一个模型提供商。"

  static func failureDescription(_ error: any Error) -> String {
    switch error {
    case PiRPCError.incompatibleRuntime:
      "Pi RPC 或受控扩展握手不兼容，请使用支持当前 RPC 协议的 Pi 与 Node 22.19+。"
    case PiRPCError.timedOut:
      "Pi RPC 请求超时。"
    case PiRPCError.invalidArgument(let field):
      field == "pi.mcp_server_unavailable"
        ? "当前任务启用的 Pi MCP 服务未能全部连接，请检查连接配置及本机服务运行状态。"
        : "Pi 配置不可用：\(field)。"
    case AgentRuntimeError.modelUnavailable("pi.no_configured_model"):
      Self.modelCatalogUnavailableReason
    case AgentRuntimeError.modelUnavailable("pi.model_catalog_unavailable"):
      Self.modelCatalogUnavailableReason
    case AgentRuntimeError.invalidRequest("pi.model_image_input_unsupported"):
      "当前选择的 Pi 模型没有声明图片输入支持，因此不能发送附件。"
    default:
      "Pi 连接或执行失败，请检查 CLI、模型认证与运行依赖。"
    }
  }
}

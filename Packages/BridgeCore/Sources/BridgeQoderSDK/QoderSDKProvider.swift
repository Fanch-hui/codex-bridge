import BridgeACP
import BridgeAgentCore
import Foundation

public struct QoderSessionResources: Sendable {
  public let skills: [String]
  public let selectedSkills: [AgentSelectedSkill]
  public let mcpServers: [String: QoderJSONValue]

  public init(
    skills: [String] = [],
    selectedSkills: [AgentSelectedSkill] = [],
    mcpServers: [String: QoderJSONValue] = [:]
  ) {
    self.skills = skills.isEmpty ? selectedSkills.map(\.name) : skills
    self.selectedSkills = selectedSkills
    self.mcpServers = mcpServers
  }
}

public struct QoderSDKProviderConfiguration: Sendable {
  public let runtimeBaseDirectory: String
  public let sourceEnvironment: [String: String]
  public let hostDirectory: String?
  public let proxy: String?
  public let runtimeConfiguration:
    @Sendable (AgentInstallation) async throws -> QoderSDKRuntimeConfiguration
  public let resources:
    @Sendable (AgentExecutionRequest, AgentInstallation) async throws -> QoderSessionResources
  public let configuredMCPServerCount: @Sendable (AgentInstallation) async throws -> Int
  public let transportFactory:
    @Sendable (ACPProcessTransportConfiguration) throws -> any ACPTransport

  public init(
    runtimeBaseDirectory: String,
    sourceEnvironment: [String: String] = ToolDiscoveryEnvironment.current(),
    hostDirectory: String? = nil, proxy: String? = nil,
    runtimeConfiguration:
      @escaping @Sendable (AgentInstallation) async throws -> QoderSDKRuntimeConfiguration = {
        installation in
        guard
          let distribution = QoderDistribution.identify(executablePath: installation.executablePath)
        else {
          throw AgentRuntimeError.invalidRequest("qoder.distribution")
        }
        return QoderSDKRuntimeConfiguration(distribution: distribution)
      },
    resources:
      @escaping @Sendable (AgentExecutionRequest, AgentInstallation) async throws ->
      QoderSessionResources = { _, _ in .init() },
    configuredMCPServerCount: @escaping @Sendable (AgentInstallation) async throws -> Int = { _ in 0
    },
    transportFactory:
      @escaping @Sendable (ACPProcessTransportConfiguration) throws -> any ACPTransport = {
        try ACPProcessTransport.launch(configuration: $0)
      }
  ) {
    self.runtimeBaseDirectory = runtimeBaseDirectory
    self.sourceEnvironment = sourceEnvironment
    self.hostDirectory = hostDirectory
    self.proxy = proxy
    self.runtimeConfiguration = runtimeConfiguration
    self.resources = resources
    self.configuredMCPServerCount = configuredMCPServerCount
    self.transportFactory = transportFactory
  }
}

public struct QoderSDKProvider: AgentProvider, AgentInstallationArtifactProviding,
  AgentNativeSessionDirectoryProviding, Sendable
{
  public let descriptor: AgentProviderDescriptor
  public let nativePermissionPolicyManager: (any AgentNativePermissionPolicyManaging)?
  private let configuration: QoderSDKProviderConfiguration

  public var nativeSessionDirectoryManager: (any AgentNativeSessionDirectoryManaging)? {
    QoderNativeSessionDirectoryManager(configuration: configuration)
  }

  public init(configuration: QoderSDKProviderConfiguration) throws {
    self.configuration = configuration
    nativePermissionPolicyManager = QoderNativePermissionPolicyManager(
      sourceEnvironment: configuration.sourceEnvironment,
      distributionResolver: { installation in
        let runtime = try await configuration.runtimeConfiguration(installation)
        if let detected = QoderDistribution.identify(executablePath: installation.executablePath),
          detected != runtime.distribution
        {
          throw AgentRuntimeError.invalidRequest("qoder.region_mismatch")
        }
        return runtime.distribution
      })
    descriptor = try AgentProviderDescriptor(
      providerID: .qoder, displayName: "Qoder", adapterRevision: 1)
  }

  public func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
    do {
      let metadata = try await inspect(installation: request.installation)
      guard let version = metadata["cliVersion"]?.stringValue else { throw ACPError.invalidMessage }
      let models = try QoderModelCatalog.parse(metadata["models"] ?? .array([]))
      guard !models.isEmpty else {
        throw AgentRuntimeError.invalidRequest("qoder.models_unavailable")
      }
      let installation = try AgentInstallation(
        id: request.installation.id, providerID: .qoder,
        executablePath: request.installation.executablePath, version: version,
        protocolRevision: "qoder-sdk-v1", artifacts: request.installation.artifacts)
      return AgentProbeResult(
        installation: installation, available: true,
        capabilities: Self.capabilities(models: models, metadata: metadata))
    } catch {
      return AgentProbeResult(
        installation: request.installation, available: false, capabilities: .empty,
        unavailableReason: Self.failureDescription(error))
    }
  }

  public func installationArtifacts(for installation: AgentInstallation) async throws
    -> [AgentInstallationArtifact]
  {
    try await QoderRuntimeProfile.make(installation: installation, configuration: configuration)
      .artifacts
  }

  public func models(installation: AgentInstallation, projectRoot _: String?) async throws
    -> [AgentModelDescriptor]
  {
    let metadata = try await inspect(installation: installation)
    return try QoderModelCatalog.parse(metadata["models"] ?? .array([]))
  }

  private func inspect(installation: AgentInstallation) async throws -> QoderJSONValue {
    let profile = try await QoderRuntimeProfile.make(
      installation: installation, configuration: configuration)
    let store = try QoderSessionStore(directory: configuration.runtimeBaseDirectory)
    let client = try profile.client(cwd: store.directory, factory: configuration.transportFactory)
    do {
      let metadata = try await client.request(
        "qoder/open",
        params: profile.parameters(
          cwd: store.directory,
          sessionID: UUID().uuidString.lowercased(), request: nil, resources: .init(),
          proxy: configuration.proxy,
          capabilityProbe: true))
      try Self.validate(metadata, distribution: profile.distribution)
      _ = try await client.request("qoder/close")
      await client.shutdown()
      var values = metadata.objectValue ?? [:]
      values["configuredMCPServerCount"] = .integer(
        Int64(try await configuration.configuredMCPServerCount(installation)))
      return .object(values)
    } catch {
      await client.shutdown()
      throw error
    }
  }

  public func start(_ request: AgentExecutionRequest, installation: AgentInstallation) async throws
    -> AgentExecutionHandle
  {
    guard
      request.workspaceStrategy == .sharedProject || request.workspaceStrategy == .exclusiveProject,
      request.profileID == nil || request.profileID?.rawValue == "qoder-managed"
    else { throw AgentRuntimeError.invalidRequest("qoder.profile") }
    let profile = try await QoderRuntimeProfile.make(
      installation: installation, configuration: configuration)
    let store = try QoderSessionStore(directory: configuration.runtimeBaseDirectory)
    let previousBinding = try store.previousBinding(
      request: request, installation: installation, distribution: profile.distribution)
    let sessionID = request.requestedSessionID ?? UUID().uuidString.lowercased()
    let resources = try await configuration.resources(request, installation)
    let client = try profile.client(
      cwd: request.projectRoot, factory: configuration.transportFactory)
    do {
      let metadata = try await client.request(
        "qoder/open",
        params: profile.parameters(
          cwd: request.projectRoot,
          sessionID: sessionID, request: request,
          resources: resources, proxy: configuration.proxy,
          expectedAccountScope: previousBinding?.accountScope))
      try Self.validate(metadata, distribution: profile.distribution)
      guard metadata["sessionID"]?.stringValue == sessionID,
        let accountScope = metadata["accountScopeDigest"]?.stringValue,
        accountScope.utf8.count == 64
      else { throw AgentRuntimeError.sessionMismatch }
      let session = try store.binding(
        request: request, installation: installation,
        distribution: profile.distribution, accountScope: accountScope, sessionID: sessionID)
      let models = try QoderModelCatalog.parse(metadata["models"] ?? .array([]))
      if !request.attachments.isEmpty {
        guard let model = request.model,
          models.first(where: { $0.id == model })?.inputModalities?.contains(.image) == true
        else {
          throw AgentRuntimeError.invalidRequest("qoder.model_image_input_unsupported")
        }
      }
      let capabilities = Self.capabilities(
        models: models, metadata: metadata, request: request, resources: resources)
      guard capabilities.supports(request.requiredCapabilities) else {
        throw AgentRuntimeError.invalidRequest("qoder.capabilities")
      }
      try store.save(session)
      let binding = try AgentBinding(
        providerID: .qoder, installationID: installation.id,
        providerSessionID: session.sessionID, providerRunID: UUID().uuidString.lowercased())
      let execution = QoderSDKExecution(
        client: client, request: request, binding: binding, distribution: profile.distribution)
      await execution.start()
      return AgentExecutionHandle(
        taskID: request.taskID, binding: binding, capabilities: capabilities,
        events: execution.events,
        control: AgentExecutionControl(
          interrupt: { try await execution.interrupt() },
          shutdown: { await execution.shutdown() }, steer: { try await execution.send($0) },
          interruptAndSteer: { try await execution.send($0, interrupt: true) },
          resolveApproval: { try await execution.resolveApproval($0, option: $1) },
          resolveUserInput: { try await execution.resolveUserInput($0, response: $1) }))
    } catch {
      await client.shutdown()
      throw error
    }
  }

  private static func validate(_ metadata: QoderJSONValue, distribution: QoderDistribution) throws {
    guard metadata["revision"]?.intValue == 1,
      metadata["distribution"]?.stringValue == distribution.rawValue,
      metadata["sdkVersion"]?.stringValue != nil
    else { throw ACPError.invalidMessage }
  }

  private static func capabilities(
    models: [AgentModelDescriptor], metadata: QoderJSONValue,
    request: AgentExecutionRequest? = nil,
    resources: QoderSessionResources = .init()
  ) -> AgentCapabilitySnapshot {
    let tools = Set(metadata["nativeTools"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    let native = Set(metadata["nativeCapabilities"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    let sdkMethods = Set(metadata["sdkMethods"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    let queryMethods = Set(metadata["queryMethods"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    let configuredMCP = metadata["configuredMCPServerCount"]?.intValue ?? 0
    var capabilities: Set<AgentCapability> = [.sessionCreate, .steer, .textDelta, .reasoningDelta]
    if sdkMethods.contains("getSessionInfo") { capabilities.insert(.sessionContinue) }
    if queryMethods.contains("interrupt") {
      capabilities.formUnion([.interrupt, .steerInterruptAndContinue])
    }
    if tools.contains("Read") || tools.contains("Glob") || tools.contains("Grep") {
      capabilities.formUnion([.workspaceRead, .readOnlyExecution])
    }
    if request?.mutationIntent == .workspaceWrite,
      !tools.isDisjoint(with: ["Write", "Edit", "NotebookEdit"])
    {
      capabilities.insert(.workspaceWriteInPlace)
    } else if request == nil, !tools.isDisjoint(with: ["Write", "Edit", "NotebookEdit"]) {
      capabilities.insert(.workspaceWriteInPlace)
    }
    if tools.count > 0 { capabilities.insert(.toolLifecycle) }
    if tools.contains("AskUserQuestion") { capabilities.insert(.structuredUserInput) }
    let approvalTools = tools.subtracting([
      "Read", "Glob", "Grep", "TaskCreate", "TaskUpdate", "TaskGet", "TaskList", "UpdateGoal",
      "AskUserQuestion",
    ])
    if !approvalTools.isEmpty {
      capabilities.formUnion([.oneShotApproval, .sessionRuleApproval, .structuredApprovalPayload])
    }
    if tools.contains("Skill"), native.contains("selected_skills_v1"),
      !resources.selectedSkills.isEmpty
    {
      capabilities.insert(.skills)
    } else if request == nil, native.contains("selected_skills_v1") {
      capabilities.insert(.skills)
    }
    if !tools.isDisjoint(with: ["TaskCreate", "TaskUpdate", "TaskGet", "TaskList", "UpdateGoal"])
      || native.contains("plan_mode_v1") && queryMethods.contains("setPlanMode")
    {
      capabilities.insert(.plan)
    }
    if queryMethods.contains("getContextUsage") || queryMethods.contains("getUsageInfo") {
      capabilities.insert(.usage)
    }
    if models.count > 1 { capabilities.insert(.modelSelection) }
    if !resources.mcpServers.isEmpty,
      metadata["mcpServers"]?.arrayValue?.isEmpty == false
        || !tools.filter({ $0.hasPrefix("mcp__") }).isEmpty
    {
      capabilities.insert(.mcpClient)
    } else if request == nil, configuredMCP > 0 {
      capabilities.insert(.mcpClient)
    }
    if request?.networkAccessRequested == true, request?.mutationIntent == .workspaceWrite {
      if tools.contains("Bash") { capabilities.insert(.shell) }
      if tools.contains("WebSearch") { capabilities.insert(.webSearch) }
      if tools.contains("WebFetch") { capabilities.insert(.webFetch) }
      if tools.contains("Agent") { capabilities.insert(.subagents) }
      if tools.contains("Agent"), native.contains("background_tasks_v1"),
        queryMethods.contains("stopTask")
      {
        capabilities.insert(.childRuns)
      }
    } else if request == nil {
      if tools.contains("Bash") { capabilities.insert(.shell) }
      if tools.contains("WebSearch") { capabilities.insert(.webSearch) }
      if tools.contains("WebFetch") { capabilities.insert(.webFetch) }
      if tools.contains("Agent") { capabilities.insert(.subagents) }
      if tools.contains("Agent"), native.contains("background_tasks_v1"),
        queryMethods.contains("stopTask")
      {
        capabilities.insert(.childRuns)
      }
    }
    if models.contains(where: { !$0.supportedReasoningEfforts.isEmpty }) {
      capabilities.insert(.effortSelection)
    }
    return AgentCapabilitySnapshot(
      advertised: capabilities, observed: capabilities, enforced: capabilities)
  }

  private static func failureDescription(_ error: any Error) -> String {
    if case ACPError.remote(_, let code) = error, code == "authentication_required" {
      return "Qoder 当前地区尚未登录或登录已失效，请使用该地区原生 CLI 登录后重新连接。"
    }
    if case AgentRuntimeError.invalidRequest(let field) = error { return "Qoder 配置不可用：\(field)" }
    if case ACPError.remote(_, let code) = error { return "Qoder SDK 通道不可用：\(code)" }
    return "Qoder SDK 连接失败，请核对地区、原生命令、Node 与对应官方 SDK。"
  }
}

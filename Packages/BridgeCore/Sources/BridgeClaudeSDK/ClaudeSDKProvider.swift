import BridgeACP
import BridgeAgentCore
import Foundation

struct ClaudeProcessStillRunning: Error {}

public struct ClaudeAuthenticationStatus: Sendable, Equatable {
  public let authenticated: Bool
  public let method: String?
}

public struct ClaudeSDKProvider: AgentProvider, AgentInstallationArtifactProviding, Sendable {
  public let descriptor: AgentProviderDescriptor
  let configuration: ClaudeSDKProviderConfiguration

  public init(configuration: ClaudeSDKProviderConfiguration) throws {
    self.configuration = configuration
    descriptor = try AgentProviderDescriptor(
      providerID: .claudeCode, displayName: "Claude Code", adapterRevision: 1)
  }

  public func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
    do {
      let metadata = try await inspect(installation: request.installation, method: "claude/probe")
      try Self.requireAuthenticated(metadata)
      let version = metadata["cliVersion"]?.stringValue
      guard let version, !version.isEmpty else { throw ACPError.invalidMessage }
      let models = try ClaudeModelCatalog.parse(metadata["models"] ?? .array([]))
      let installation = try AgentInstallation(
        id: request.installation.id, providerID: .claudeCode,
        executablePath: request.installation.executablePath, version: version,
        protocolRevision: "claude-sdk-v1", artifacts: request.installation.artifacts)
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
    try await ClaudeRuntimeProfile.make(installation: installation, configuration: configuration)
      .artifacts
  }

  public func isAuthenticated(installation: AgentInstallation) async throws -> Bool {
    try await authenticationStatus(installation: installation).authenticated
  }

  public func authenticationStatus(installation: AgentInstallation) async throws
    -> ClaudeAuthenticationStatus
  {
    let metadata = try await inspect(installation: installation, method: "claude/auth")
    guard let value = metadata["authenticated"]?.boolValue else { throw ACPError.invalidMessage }
    let method = metadata["authMethod"]?.stringValue
    let allowed = [
      "none", "claude.ai", "oauth_token", "api_key", "api_key_helper", "third_party", "unknown",
    ]
    if let method, !allowed.contains(method) { throw ACPError.invalidMessage }
    return ClaudeAuthenticationStatus(authenticated: value, method: method)
  }

  public func models(installation: AgentInstallation, projectRoot: String?) async throws
    -> [AgentModelDescriptor]
  {
    let metadata = try await inspect(
      installation: installation, method: "claude/catalog", projectRoot: projectRoot)
    try Self.requireAuthenticated(metadata)
    return try ClaudeModelCatalog.parse(metadata["models"] ?? .array([]))
  }

  func inspect(
    installation: AgentInstallation, method: String, projectRoot: String? = nil
  ) async throws -> ACPJSONValue {
    let profile = try await ClaudeRuntimeProfile.make(
      installation: installation, configuration: configuration)
    let store = try ClaudeSessionStore(directory: configuration.runtimeBaseDirectory)
    let cwd = projectRoot ?? store.directory
    let client = try profile.client(cwd: cwd, factory: configuration.transportFactory)
    do {
      let result = try await client.request(
        method,
        params: profile.parameters(
          cwd: cwd, sessionID: UUID().uuidString.lowercased(), request: nil, resources: .init()))
      try Self.validate(result)
      guard await client.shutdown() else { throw ClaudeProcessStillRunning() }
      return result
    } catch {
      guard await client.shutdown() else { throw ClaudeProcessStillRunning() }
      throw error
    }
  }

  public func start(_ request: AgentExecutionRequest, installation: AgentInstallation) async throws
    -> AgentExecutionHandle
  {
    guard
      (request.workspaceStrategy == .sharedProject
        || request.workspaceStrategy == .exclusiveProject)
        && request.workspaceIsolation == nil
        || request.workspaceStrategy == .isolatedGitWorktree && request.workspaceIsolation != nil,
      request.profileID == nil || request.profileID?.rawValue == "claude-managed"
    else { throw AgentRuntimeError.invalidRequest("claude.profile") }
    let profile = try await ClaudeRuntimeProfile.make(
      installation: installation, configuration: configuration)
    let store = try ClaudeSessionStore(directory: configuration.runtimeBaseDirectory)
    let sessionID = request.requestedSessionID ?? UUID().uuidString.lowercased()
    guard UUID(uuidString: sessionID) != nil else { throw AgentRuntimeError.sessionMismatch }
    let lease = try await ClaudeSessionLeases.shared.acquire(
      installationID: installation.id.rawValue, sessionID: sessionID)
    do {
      return try await launch(
        request, installation: installation, profile: profile, store: store,
        sessionID: sessionID, lease: lease)
    } catch is ClaudeProcessStillRunning {
      throw AgentRuntimeError.processUnavailable
    } catch {
      await ClaudeSessionLeases.shared.release(lease)
      throw error
    }
  }

  private func launch(
    _ request: AgentExecutionRequest, installation: AgentInstallation,
    profile: ClaudeRuntimeProfile, store: ClaudeSessionStore, sessionID: String, lease: String
  ) async throws -> AgentExecutionHandle {
    let resources = try await configuration.resources(request, installation)
    var expectedIdentity: String?
    if request.workspaceIsolation != nil {
      guard resources.mcpServers.isEmpty,
        try await configuration.configuredMCPServerCount(installation) == 0
      else { throw AgentRuntimeError.invalidRequest("claude.isolation_mcp") }
      expectedIdentity = try await authenticationIdentity(
        installation: installation, projectRoot: request.projectRoot)
    }
    let client = try profile.client(
      cwd: request.projectRoot, isolation: request.workspaceIsolation,
      factory: configuration.transportFactory)
    do {
      let probe = try await client.request(
        "claude/auth",
        params: profile.parameters(
          cwd: request.projectRoot, sessionID: sessionID, request: nil, resources: .init()))
      try Self.validate(probe)
      try Self.requireAuthenticated(probe)
      if let expectedIdentity {
        guard probe["identityScopeVerified"]?.boolValue == true,
          probe["identityScopeDigest"]?.stringValue == expectedIdentity
        else { throw AgentRuntimeError.sessionMismatch }
      }
      guard let scope = probe["configScopeDigest"]?.stringValue else {
        throw AgentRuntimeError.sessionMismatch
      }
      let session = try store.binding(
        request: request, installation: installation, sessionID: sessionID,
        configScopeDigest: scope)
      let runID = UUID().uuidString.lowercased()
      let metadata = try await client.request(
        "claude/start",
        params: profile.parameters(
          cwd: request.projectRoot, sessionID: sessionID, runID: runID,
          request: request, resources: resources, expectedAccountScope: scope))
      try Self.validate(metadata)
      guard metadata["sessionID"]?.stringValue == sessionID,
        metadata["configScopeDigest"]?.stringValue == scope
      else { throw AgentRuntimeError.sessionMismatch }
      let models = try ClaudeModelCatalog.parse(metadata["models"] ?? .array([]))
      let capabilities = Self.capabilities(models: models, metadata: metadata, request: request)
      guard capabilities.supports(request.requiredCapabilities) else {
        throw AgentRuntimeError.invalidRequest("claude.capabilities")
      }
      if !request.selectedSkills.isEmpty, !capabilities.effective.contains(.skills) {
        throw AgentRuntimeError.capabilityUnavailable(.skills)
      }
      if !resources.mcpServers.isEmpty, !capabilities.effective.contains(.mcpClient) {
        throw AgentRuntimeError.capabilityUnavailable(.mcpClient)
      }
      try store.save(session)
      let binding = try AgentBinding(
        providerID: .claudeCode, installationID: installation.id,
        providerSessionID: sessionID, providerRunID: runID)
      let execution = ClaudeSDKExecution(
        client: client, request: request, binding: binding, sessionLease: lease)
      try await execution.start()
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
      guard await client.shutdown() else { throw ClaudeProcessStillRunning() }
      throw error
    }
  }

  static func validate(_ metadata: ACPJSONValue) throws {
    guard metadata["revision"]?.intValue == 1,
      metadata["sdkVersion"]?.stringValue == "0.3.317"
    else { throw AgentRuntimeError.unsupportedProtocol("claude-sdk-v1") }
  }

  static func requireAuthenticated(_ value: ACPJSONValue) throws {
    guard let authenticated = value["authenticated"]?.boolValue else {
      throw ACPError.invalidMessage
    }
    guard authenticated else {
      throw AgentRuntimeError.invalidRequest("claude.authentication_required")
    }
  }

  private static func failureDescription(_ error: any Error) -> String {
    if error is ClaudeProcessStillRunning {
      return "Claude Code 后台进程尚未确认退出，请检查进程状态后重新连接。"
    }
    if case AgentRuntimeError.invalidRequest("claude.authentication_required") = error {
      return "Claude Code 尚未登录，请使用官方 CLI 登录后重新连接。"
    }
    if case AgentRuntimeError.invalidRequest(let field) = error {
      return "Claude Code 配置不可用：\(field)"
    }
    if case ACPError.remote(_, let code) = error { return "Claude Code SDK 通道不可用：\(code)" }
    return "Claude Code 连接失败，请检查官方 CLI、Node 和 SDK 运行资源。"
  }
}

import BridgeACP
import BridgeAgentCore
import BridgeSecurity
import Foundation

struct ClaudeRuntimeProfile {
  let node: String
  let cli: String
  let nodeArtifact: SecureFileArtifactSnapshot
  let cliArtifact: SecureFileArtifactSnapshot
  let host: String
  let environment: [String: String]
  let artifacts: [AgentInstallationArtifact]

  static func make(installation: AgentInstallation, configuration: ClaudeSDKProviderConfiguration)
    async throws -> Self
  {
    guard installation.providerID == .claudeCode else {
      throw AgentRuntimeError.providerUnavailable(installation.providerID)
    }
    let runtime = try await configuration.runtimeConfiguration(installation)
    let cli = try SecureFileArtifactSnapshot.capture(
      at: installation.executablePath, requiresExecutable: true)
    let path =
      runtime.nodeExecutablePath
      ?? installation.artifacts.first(where: { $0.role == .nodeInterpreter })?.canonicalPath
      ?? AgentNodeExecutableResolver.resolve(
        near: cli.canonicalPath, environment: configuration.sourceEnvironment)
      ?? AgentExecutableResolver(environment: configuration.sourceEnvironment).resolve("node")
    guard let path, AgentPathSemantics.isAbsolute(path) else {
      throw AgentRuntimeError.invalidRequest("claude.node_missing")
    }
    let node = try SecureFileArtifactSnapshot.capture(at: path, requiresExecutable: true)
    let host = try ClaudeRuntimeResources.load(
      directory: runtime.hostDirectory ?? configuration.hostDirectory)
    let artifacts = [
      artifact(node, role: .nodeInterpreter), artifact(host.entry, role: .launchConfiguration),
      artifact(host.lock, role: .runtimeManifest), artifact(host.vendor, role: .dependencyLock),
    ]
    try validateRegisteredArtifacts(installation.artifacts, current: artifacts)
    let home = try AgentProviderEnvironment.homeDirectory(source: configuration.sourceEnvironment)
    var environment = [
      "HOME": home,
      "PATH": AgentProviderEnvironment.executableSearchPath(
        executablePath: node.canonicalPath, source: configuration.sourceEnvironment),
    ]
    #if os(Windows)
      AgentProviderEnvironment.applyWindowsSystemEnvironment(
        to: &environment, from: configuration.sourceEnvironment)
      environment["USERPROFILE"] = home
    #endif
    for key in [
      "CLAUDE_CONFIG_DIR", "TMPDIR", "TEMP", "TMP", "LANG", "LC_ALL", "SHELL", "USER", "LOGNAME",
      "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy",
      "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN",
      "ANTHROPIC_FOUNDRY_API_KEY", "ANTHROPIC_FOUNDRY_BASE_URL", "ANTHROPIC_FOUNDRY_RESOURCE",
      "AWS_BEARER_TOKEN_BEDROCK", "ANTHROPIC_BEDROCK_BASE_URL", "ANTHROPIC_VERTEX_BASE_URL",
      "CLAUDE_CODE_USE_BEDROCK",
      "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "AWS_REGION", "CLOUD_ML_REGION",
      "AWS_DEFAULT_REGION", "AWS_PROFILE", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY",
      "AWS_SESSION_TOKEN",
      "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_CLOUD_PROJECT", "GCLOUD_PROJECT",
      "ANTHROPIC_VERTEX_PROJECT_ID", "AZURE_AI_PROJECT_ENDPOINT", "ANTHROPIC_BEDROCK_BASE_URL",
      "ANTHROPIC_VERTEX_BASE_URL", "ANTHROPIC_FOUNDRY_BASE_URL", "AWS_DEFAULT_REGION",
      "AWS_PROFILE", "GOOGLE_CLOUD_PROJECT", "GOOGLE_CLOUD_REGION", "AZURE_AI_PROJECT_NAME",
    ] {
      if let value = configuration.sourceEnvironment[key], !value.contains("\0"),
        value.utf8.count <= 32768
      {
        environment[key] = value
      }
    }
    return Self(
      node: node.canonicalPath, cli: cli.canonicalPath, nodeArtifact: node, cliArtifact: cli,
      host: host.entry.canonicalPath, environment: environment, artifacts: artifacts)
  }

  func client(
    cwd: String, isolation: AgentWorkspaceIsolation? = nil,
    factory: @Sendable (ACPProcessTransportConfiguration) throws -> any ACPTransport
  ) throws -> ClaudeSDKClient {
    var launch = ACPProcessTransportConfiguration(
      argv: [node, host], workingDirectory: cwd, environment: environment,
      maximumFrameBytes: 16_777_216, maximumStandardErrorBytes: 65536,
      inputEOFGracePeriod: .seconds(15))
    if let isolation {
      launch = try ClaudeWorkspaceIsolation.prepare(
        launch, runtimeDirectory: isolation.runtimeDirectory,
        cliArtifact: cliArtifact, nodeArtifact: nodeArtifact)
    }
    return ClaudeSDKClient(transport: try factory(launch))
  }

  func parameters(
    cwd: String, sessionID: String, runID: String? = nil, request: AgentExecutionRequest?,
    resources: ClaudeSessionResources, expectedAccountScope: String? = nil, isolated: Bool? = nil
  ) -> ACPJSONValue {
    var values: [String: ACPJSONValue] = [
      "revision": .integer(1), "cwd": .string(cwd), "cliPath": .string(cli),
      "sessionID": .string(sessionID), "resume": .bool(request?.requestedSessionID != nil),
      "mode": .string(request?.mutationIntent == .workspaceWrite ? "workspace-write" : "read-only"),
      "networkAllowed": .bool(request?.networkAccessRequested == true),
      "nativeSubagentsAllowed": .bool(request?.nativeSubagentsAllowed ?? true),
      "autoApprove": .bool(request?.toolApprovalPolicy == .autoApprove),
      "isolated": .bool(isolated ?? (request?.workspaceIsolation != nil)),
      "writeGate": .bool(request?.toolWriteGate != nil),
      "mcpServers": .object(resources.mcpServers),
      "selectedSkills": .array(resources.selectedSkills.map(Self.skillValue)),
    ]
    if let model = request?.model { values["model"] = .string(model) }
    if let effort = request?.effort { values["effort"] = .string(effort) }
    if let taskID = request?.taskID.rawValue { values["taskID"] = .string(taskID) }
    if let runID { values["runID"] = .string(runID) }
    if let expectedAccountScope { values["expectedAccountScope"] = .string(expectedAccountScope) }
    return .object(values)
  }

  private static func skillValue(_ skill: AgentSelectedSkill) -> ACPJSONValue {
    .object([
      "name": .string(skill.name), "source": .string(skill.source.rawValue),
      "contentVersion": .string(skill.contentVersion),
      "files": .array(
        skill.files.map { file in
          .object(["relativePath": .string(file.relativePath), "content": .string(file.content)])
        }),
    ])
  }

  private static func validateRegisteredArtifacts(
    _ registered: [AgentInstallationArtifact], current: [AgentInstallationArtifact]
  ) throws {
    guard !registered.isEmpty else { return }
    let values = Dictionary(uniqueKeysWithValues: current.map { ($0.role, $0) })
    for recorded in registered {
      guard let actual = values[recorded.role], recorded.canonicalPath == actual.canonicalPath,
        recorded.sha256 == actual.sha256
      else { throw SecureFileArtifactError.changed }
    }
  }

  private static func artifact(
    _ value: SecureFileArtifactSnapshot, role: AgentInstallationArtifactRole
  )
    -> AgentInstallationArtifact
  {
    AgentInstallationArtifact(
      role: role, canonicalPath: value.canonicalPath, device: value.device, inode: value.inode,
      fileSize: value.fileSize, modificationTimeNanoseconds: value.modificationTimeNanoseconds,
      sha256: value.sha256)
  }
}

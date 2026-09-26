import BridgeAgentCore
import BridgeSecurity
import Foundation

struct PiRuntimeProfile: Sendable {
  let launch: PiRPCLaunch
  let nonce: String
  let sessionID: String?
  let store: PiSessionStore?
  let tools: [String]
  let mcpServerIDs: [String]
  let selectedSkillStage: PiSelectedSkillStage?
  let artifacts: [AgentInstallationArtifact]

  static func make(
    installation: AgentInstallation,
    request: AgentExecutionRequest?,
    configuration: PiRPCProviderConfiguration,
    nativePermissionRules: [AgentNativePermissionRuleSnapshot] = [],
    mcpServers: [AgentMCPServerConfiguration] = []
  ) throws -> PiRuntimeProfile {
    guard installation.providerID == .pi else {
      throw AgentRuntimeError.providerUnavailable(installation.providerID)
    }
    let executable = try SecureFileArtifactSnapshot.capture(at: installation.executablePath)
    let environmentSource = configuration.sourceEnvironment
    guard
      let node = AgentNodeExecutableResolver.resolve(
        near: installation.executablePath, environment: environmentSource)
    else {
      throw PiRPCError.invalidArgument("node_runtime_missing")
    }
    let nodeSnapshot = try SecureFileArtifactSnapshot.capture(at: node, requiresExecutable: true)
    let invocation = try PiExecutableResolver.resolve(executable: executable, node: nodeSnapshot)
    let resource = try PiRuntimeResources.load(directory: configuration.extensionDirectory)
    #if os(Windows)
      let attributes: [FileAttributeKey: Any]? = nil
    #else
      let attributes: [FileAttributeKey: Any]? = [.posixPermissions: 0o700]
    #endif
    try FileManager.default.createDirectory(
      atPath: configuration.runtimeBaseDirectory, withIntermediateDirectories: true,
      attributes: attributes)
    let root = try RegisteredRoot(
      capturing: URL(fileURLWithPath: configuration.runtimeBaseDirectory))
    let cwd = request?.projectRoot ?? root.canonicalPath
    let project = try RegisteredRoot(capturing: URL(fileURLWithPath: cwd))
    let nonce = UUID().uuidString.lowercased()
    let tools = activeTools(request: request)
    let activeMCPServers =
      request?.mutationIntent == .workspaceWrite
        && request?.networkAccessRequested == true ? mcpServers : []
    let store = try request.map {
      try PiSessionStore(
        baseDirectory: root.canonicalPath,
        installationID: installation.id.rawValue, projectID: $0.projectID.rawValue)
    }
    let sessionID: String?
    var argv =
      invocation.executableArgv + [
        "--mode", "rpc", "--no-extensions",
        "--no-skills", "--no-prompt-templates", "--no-themes", "--no-approve",
        "--offline", "-e", resource.entryPath, "--tools", tools.joined(separator: ","),
      ]
    if let request, let store {
      argv += ["--session-dir", store.sessionsDirectory]
      if let previousID = request.requestedSessionID {
        let previous = try store.load(
          sessionID: previousID, request: request, installation: installation)
        sessionID = previous.sessionID
        argv += ["--session", previous.sessionFile]
      } else {
        let newSessionID = UUID().uuidString.lowercased()
        sessionID = newSessionID
        argv += ["--session-id", newSessionID]
      }
    } else {
      sessionID = nil
      argv.append("--no-session")
    }
    var environment = try processEnvironment(executable: node, source: environmentSource)
    let skillPaths = PiSelectedSkillStage.directoryPaths(
      count: request?.selectedSkills.count ?? 0, runtimeRoot: root, nonce: nonce)
    let permissionRules = nativePermissionRules.map { rule in
      PiJSONValue.object([
        "effect": .string(rule.effect.rawValue), "action": .string(rule.action),
        "target": .string(rule.target),
      ])
    }
    let context = PiJSONValue.object([
      "revision": .integer(1), "nonce": .string(nonce),
      "projectRoot": .string(project.canonicalPath),
      "taskID": .string(request?.taskID.rawValue ?? "probe"),
      "mode": .string(request?.mutationIntent == .workspaceWrite ? "workspace-write" : "read-only"),
      "networkAllowed": .bool(request?.networkAccessRequested ?? false),
      "tools": .array(tools.map(PiJSONValue.string)),
      "cliArgv": .array(invocation.executableArgv.map(PiJSONValue.string)),
      "skillPaths": .array(skillPaths.map(PiJSONValue.string)),
      "nativePermissionRules": .array(permissionRules),
      "mcpServers": .array(try PiMCPServerContext.values(activeMCPServers)),
    ])
    environment["CODEX_BRIDGE_PI_CONTEXT"] = try context.text()
    let selectedSkillStage = try PiSelectedSkillStage.create(
      skills: request?.selectedSkills ?? [], runtimeRoot: root, nonce: nonce)
    for directory in selectedSkillStage?.skillDirectories ?? [] {
      argv += ["--skill", directory]
    }
    return PiRuntimeProfile(
      launch: PiRPCLaunch(
        argv: argv, executableArgv: invocation.executableArgv,
        workingDirectory: project.canonicalPath, environment: environment),
      nonce: nonce, sessionID: sessionID, store: store, tools: tools,
      mcpServerIDs: activeMCPServers.map(\.id),
      selectedSkillStage: selectedSkillStage,
      artifacts: [artifact(resource.entry, role: .launchConfiguration)] + invocation.artifacts + [
        artifact(nodeSnapshot, role: .nodeInterpreter)
      ])
  }

  private static func activeTools(request: AgentExecutionRequest?) -> [String] {
    var tools = ["read", "grep", "find", "ls", "bridge_plan", "bridge_ask_user", "bridge_subtask"]
    guard request?.mutationIntent == .workspaceWrite else { return tools }
    tools += ["write", "edit"]
    if request?.networkAccessRequested == true {
      #if os(Windows)
        tools.append("powershell")
      #else
        tools.append("bash")
      #endif
    }
    return tools
  }

  private static func processEnvironment(executable: String, source: [String: String]) throws
    -> [String: String]
  {
    let home = try AgentProviderEnvironment.homeDirectory(source: source)
    var result = [
      "HOME": home,
      "PATH": AgentProviderEnvironment.executableSearchPath(
        executablePath: executable, source: source), "PI_OFFLINE": "1",
    ]
    #if os(Windows)
      AgentProviderEnvironment.applyWindowsSystemEnvironment(to: &result, from: source)
      result["USERPROFILE"] = home
    #endif
    let keys = [
      "USER", "LOGNAME", "LANG", "LC_ALL", "SHELL", "TEMP", "TMP", "TMPDIR",
      "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy",
      "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY",
      "OPENROUTER_API_KEY", "GROQ_API_KEY", "XAI_API_KEY", "DEEPSEEK_API_KEY",
      "MISTRAL_API_KEY", "AZURE_OPENAI_API_KEY", "AZURE_OPENAI_ENDPOINT",
    ]
    for key in keys {
      if let value = source[key], !value.contains("\0"), value.utf8.count <= 32 * 1_024 {
        result[key] = value
      }
    }
    return result
  }

  private static func artifact(
    _ value: SecureFileArtifactSnapshot, role: AgentInstallationArtifactRole
  )
    -> AgentInstallationArtifact
  {
    AgentInstallationArtifact(
      role: role, canonicalPath: value.canonicalPath,
      device: value.device, inode: value.inode, fileSize: value.fileSize,
      modificationTimeNanoseconds: value.modificationTimeNanoseconds, sha256: value.sha256)
  }
}

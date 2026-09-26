import BridgeACP
import BridgeAgentCore
import BridgeSecurity
import Foundation

struct QoderRuntimeProfile {
  let distribution: QoderDistribution
  let node: String
  let cli: String
  let sdkRoot: String
  let host: String
  let environment: [String: String]
  let artifacts: [AgentInstallationArtifact]

  static func make(installation: AgentInstallation, configuration: QoderSDKProviderConfiguration)
    async throws
    -> Self
  {
    guard installation.providerID == .qoder else {
      throw AgentRuntimeError.providerUnavailable(installation.providerID)
    }
    let runtime = try await configuration.runtimeConfiguration(installation)
    if let detected = QoderDistribution.identify(executablePath: installation.executablePath),
      detected != runtime.distribution
    {
      throw AgentRuntimeError.invalidRequest("qoder.region_mismatch")
    }
    let suffix = URL(fileURLWithPath: installation.executablePath).pathExtension.lowercased()
    guard suffix != "cmd", suffix != "bat" else {
      throw AgentRuntimeError.invalidRequest("qoder.native_cli_required")
    }
    let cli = try SecureFileArtifactSnapshot.capture(at: installation.executablePath)
    let nodePath = try resolveNode(
      runtime.nodeExecutablePath, near: cli.canonicalPath,
      environment: configuration.sourceEnvironment)
    let node = try SecureFileArtifactSnapshot.capture(at: nodePath, requiresExecutable: true)
    let sdkRoot = try resolveSDKRoot(
      runtime.sdkRoot, distribution: runtime.distribution,
      cli: cli.canonicalPath, node: node.canonicalPath, environment: configuration.sourceEnvironment
    )
    let sdk = try sdkArtifacts(root: sdkRoot, distribution: runtime.distribution)
    let host = try QoderRuntimeResources.load(directory: configuration.hostDirectory)
    let artifacts = [
      artifact(node, role: .nodeInterpreter), artifact(sdk.manifest, role: .runtimeManifest),
      artifact(sdk.entry, role: .dependencyLock), artifact(host.entry, role: .launchConfiguration),
    ]
    try validateRecordedArtifacts(installation.artifacts, against: artifacts)

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
    let regionKey = runtime.distribution == .cn ? "QODERCN_CONFIG_DIR" : "QODER_CONFIG_DIR"
    for key in [
      regionKey, "TMPDIR", "TEMP", "TMP", "LANG", "LC_ALL", "SHELL", "USER", "LOGNAME",
      "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy",
    ] {
      if let value = configuration.sourceEnvironment[key], !value.contains("\0"),
        value.utf8.count <= 32768
      {
        environment[key] = value
      }
    }
    return Self(
      distribution: runtime.distribution, node: node.canonicalPath, cli: cli.canonicalPath,
      sdkRoot: sdkRoot, host: host.entry.canonicalPath, environment: environment,
      artifacts: artifacts)
  }

  func client(
    cwd: String, factory: @Sendable (ACPProcessTransportConfiguration) throws -> any ACPTransport
  ) throws
    -> QoderSDKClient
  {
    let launch = ACPProcessTransportConfiguration(
      argv: [node, host], workingDirectory: cwd,
      environment: environment, maximumFrameBytes: 16_777_216, maximumStandardErrorBytes: 65536,
      inputEOFGracePeriod: .seconds(15))
    return QoderSDKClient(transport: try factory(launch))
  }

  func parameters(
    cwd: String, sessionID: String, request: AgentExecutionRequest?,
    resources: QoderSessionResources,
    proxy: String?, capabilityProbe: Bool = false, expectedAccountScope: String? = nil
  ) -> QoderJSONValue {
    var values: [String: QoderJSONValue] = [
      "revision": .integer(1), "distribution": .string(distribution.rawValue), "cwd": .string(cwd),
      "cliPath": .string(cli), "nodePath": .string(node), "sdkRoot": .string(sdkRoot),
      "sessionID": .string(sessionID), "resume": .bool(request?.requestedSessionID != nil),
      "persist": .bool(request != nil),
      "mode": .string(
        request?.mutationIntent == .workspaceWrite || capabilityProbe
          ? "workspace-write" : "read-only"),
      "networkAllowed": .bool(request?.networkAccessRequested == true || capabilityProbe),
      "skills": .array(resources.skills.map(QoderJSONValue.string)),
      "selectedSkills": .array(resources.selectedSkills.map(selectedSkillValue)),
      "mcpServers": .object(resources.mcpServers),
    ]
    if let model = request?.model { values["model"] = .string(model) }
    if let effort = request?.effort { values["effort"] = .string(effort) }
    if let expectedAccountScope { values["expectedAccountScope"] = .string(expectedAccountScope) }
    if let proxy { values["proxy"] = .string(proxy) }
    return .object(values)
  }

  private func selectedSkillValue(_ skill: AgentSelectedSkill) -> QoderJSONValue {
    .object([
      "name": .string(skill.name),
      "source": .string(skill.source.rawValue),
      "contentVersion": .string(skill.contentVersion),
      "files": .array(
        skill.files.map { file in
          .object([
            "relativePath": .string(file.relativePath),
            "content": .string(file.content),
          ])
        }),
    ])
  }

  private static func resolveNode(
    _ configured: String?, near cli: String, environment: [String: String]
  ) throws -> String {
    let path =
      configured
      ?? AgentNodeExecutableResolver.resolve(near: cli, environment: environment)
      ?? AgentExecutableResolver(environment: environment).resolve("node")
    guard let path else { throw AgentRuntimeError.invalidRequest("qoder.node_missing") }
    guard AgentPathSemantics.isAbsolute(path) else {
      throw AgentRuntimeError.invalidRequest("qoder.node_path")
    }
    return path
  }

  private static func resolveSDKRoot(
    _ configured: String?, distribution: QoderDistribution, cli: String,
    node: String, environment: [String: String]
  ) throws -> String {
    if let configured {
      guard AgentPathSemantics.isAbsolute(configured) else {
        throw AgentRuntimeError.invalidRequest("qoder.sdk_root")
      }
      return try RegisteredRoot(capturing: URL(fileURLWithPath: configured)).canonicalPath
    }
    let package =
      distribution == .cn ? "@qodercn-ai/qodercn-agent-sdk" : "@qoder-ai/qoder-agent-sdk"
    let nodeDirectory = URL(fileURLWithPath: node).deletingLastPathComponent()
    var bases = nodeModulesDirectories(above: URL(fileURLWithPath: cli))
    bases.append(contentsOf: [
      nodeDirectory.appendingPathComponent("node_modules"),
      nodeDirectory.deletingLastPathComponent().appendingPathComponent("lib")
        .appendingPathComponent("node_modules"),
    ])
    if let appData = environment["APPDATA"] {
      bases.append(
        URL(fileURLWithPath: appData).appendingPathComponent("npm").appendingPathComponent(
          "node_modules"))
    }
    for base in bases {
      let candidate = base.appendingPathComponent(package)
      if FileManager.default.fileExists(
        atPath: candidate.appendingPathComponent("package.json").path)
      {
        return try RegisteredRoot(capturing: candidate).canonicalPath
      }
    }
    throw AgentRuntimeError.invalidRequest("qoder.sdk_missing." + distribution.rawValue)
  }

  private static func nodeModulesDirectories(above path: URL) -> [URL] {
    var current = path.deletingLastPathComponent()
    var directories: [URL] = []
    for _ in 0..<32 {
      guard current.path != current.deletingLastPathComponent().path else { break }
      if current.lastPathComponent == "node_modules" { directories.append(current) }
      current = current.deletingLastPathComponent()
    }
    if directories.isEmpty {
      directories.append(path.deletingLastPathComponent().appendingPathComponent("node_modules"))
    }
    return directories
  }

  private static func sdkArtifacts(root: String, distribution: QoderDistribution)
    throws -> (manifest: SecureFileArtifactSnapshot, entry: SecureFileArtifactSnapshot)
  {
    let resolver = ProjectPathResolver(
      root: try RegisteredRoot(capturing: URL(fileURLWithPath: root)))
    let manifestFile = try SecureFileReader(maximumBytes: 131072, maximumLines: 4096)
      .read(try SecureRelativePath("package.json"), through: resolver)
    let manifest = try SecureFileArtifactSnapshot.capture(
      at: URL(fileURLWithPath: root)
        .appendingPathComponent("package.json").path, maximumBytes: 131072)
    guard manifest.sha256 == manifestFile.sha256 else { throw SecureFileArtifactError.changed }
    let document = try JSONSerialization.jsonObject(with: Data(manifestFile.text.utf8))
    guard let object = document as? [String: Any],
      object["name"] as? String == packageName(distribution),
      object["qoderSdkBrand"] as? String == sdkBrand(distribution),
      let entryPath = moduleEntry(object), entryPath.hasPrefix("./")
    else { throw AgentRuntimeError.invalidRequest("qoder.sdk_distribution_mismatch") }
    let entryURL = URL(fileURLWithPath: root).appendingPathComponent(entryPath).standardizedFileURL
    guard AgentPathSemantics.isContained(entryURL.path, in: root) else {
      throw AgentRuntimeError.invalidRequest("qoder.sdk_entry_outside_package")
    }
    let entry = try SecureFileArtifactSnapshot.capture(
      at: entryURL.path, maximumBytes: 16 * 1_024 * 1_024)
    guard AgentPathSemantics.isContained(entry.canonicalPath, in: root) else {
      throw AgentRuntimeError.invalidRequest("qoder.sdk_entry_outside_package")
    }
    return (manifest, entry)
  }

  private static func packageName(_ distribution: QoderDistribution) -> String {
    distribution == .cn ? "@qodercn-ai/qodercn-agent-sdk" : "@qoder-ai/qoder-agent-sdk"
  }

  private static func sdkBrand(_ distribution: QoderDistribution) -> String {
    distribution == .cn ? "cn" : "global"
  }

  private static func moduleEntry(_ manifest: [String: Any]) -> String? {
    if let exports = manifest["exports"] as? [String: Any] {
      if let root = exports["."] as? String { return root }
      if let root = exports["."] as? [String: Any],
        let entry = root["import"] as? String ?? root["default"] as? String
      {
        return entry
      }
    }
    return manifest["main"] as? String
  }

  private static func validateRecordedArtifacts(
    _ registered: [AgentInstallationArtifact],
    against current: [AgentInstallationArtifact]
  ) throws {
    guard !registered.isEmpty else { return }
    let expected = Dictionary(uniqueKeysWithValues: current.map { ($0.role, $0) })
    guard registered.count == current.count,
      registered.allSatisfy({ artifact in
        guard let value = expected[artifact.role] else { return false }
        return value.canonicalPath == artifact.canonicalPath && value.sha256 == artifact.sha256
      })
    else { throw SecureFileArtifactError.changed }
  }

  private static func artifact(
    _ value: SecureFileArtifactSnapshot, role: AgentInstallationArtifactRole
  )
    -> AgentInstallationArtifact
  {
    AgentInstallationArtifact(
      role: role, canonicalPath: value.canonicalPath, device: value.device,
      inode: value.inode, fileSize: value.fileSize,
      modificationTimeNanoseconds: value.modificationTimeNanoseconds,
      sha256: value.sha256)
  }
}

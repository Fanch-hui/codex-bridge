import BridgeAgentCore
import Foundation

#if !os(Windows)
  #if canImport(Darwin)
    import Darwin
  #elseif canImport(Glibc)
    import Glibc
  #endif
#endif

extension DeepSeekHarnessACPLaunchBuilder {
  func prepareRuntimeProfile(
    sourceRoot: String,
    runDirectory: String,
    configurationData: Data? = nil,
    modelID: String? = nil,
    reasoningEffort: String? = nil,
    mutationIntent: AgentMutationIntent = .readOnly
  ) throws -> String {
    let moduleDirectory = try DeepSeekHarnessACPPathSupport.append(
      ["node_modules", ".pnpm", "node_modules"],
      to: sourceRoot,
      isDirectory: true
    )
    let resolvedModuleDirectory = URL(fileURLWithPath: moduleDirectory, isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL.path
    var isDirectory: ObjCBool = false
    guard DeepSeekHarnessACPPathSupport.samePath(resolvedModuleDirectory, moduleDirectory),
      FileManager.default.fileExists(atPath: moduleDirectory, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw DeepSeekHarnessACPError.artifactInvalid("runtime_modules")
    }

    let runtimeProfile = try DeepSeekHarnessACPPathSupport.append(
      "profile",
      to: runDirectory,
      isDirectory: true
    )
    try DeepSeekHarnessACPPathSupport.createPrivateDirectory(runtimeProfile)
    let configuration = try DeepSeekHarnessACPPathSupport.append("cordis.yml", to: runtimeProfile)
    do {
      let stagedConfiguration = try DeepSeekHarnessACPModelCatalog.runtimeConfiguration(
        from: configurationData ?? profile.configurationTemplate,
        template: profile.configurationTemplate,
        modelID: modelID,
        reasoningEffort: reasoningEffort
      )
      let runtimeConfiguration = try Self.replaceSandboxMode(
        in: stagedConfiguration,
        mutationIntent: mutationIntent
      )
      try runtimeConfiguration.write(
        to: URL(fileURLWithPath: configuration),
        options: .atomic
      )
      #if !os(Windows)
        guard chmod(configuration, 0o600) == 0 else {
          throw AgentRuntimeError.processUnavailable
        }
      #endif
      try DeepSeekHarnessACPDirectoryLink.createDirectoryLink(
        atPath: try DeepSeekHarnessACPPathSupport.append("node_modules", to: runtimeProfile),
        destinationPath: moduleDirectory
      )
      return configuration
    } catch let error as AgentRuntimeError {
      throw error
    } catch {
      throw AgentRuntimeError.processUnavailable
    }
  }

  public static func removeRunDirectory(_ path: String) {
    guard !path.isEmpty, AgentPathSemantics.isAbsolute(path),
      let canonical = AgentPathSemantics.canonicalPath(path),
      AgentPathSemantics.directoryPath(of: canonical) != nil
    else { return }
    if let linkPath = try? DeepSeekHarnessACPPathSupport.append(
      "node_modules",
      to: DeepSeekHarnessACPPathSupport.append("profile", to: canonical, isDirectory: true)
    ) {
      DeepSeekHarnessACPDirectoryLink.removeDirectoryLink(atPath: linkPath)
    }
    try? FileManager.default.removeItem(atPath: canonical)
  }

  static func permissionMode(for mutationIntent: AgentMutationIntent) -> String {
    switch mutationIntent {
    case .readOnly:
      "read-only"
    case .workspaceWrite:
      "workspace-write"
    }
  }

  static func replaceSandboxMode(
    in configuration: Data,
    mutationIntent: AgentMutationIntent
  ) throws -> Data {
    guard var value = String(data: configuration, encoding: .utf8) else {
      throw DeepSeekHarnessACPError.templateMismatch
    }
    let prefix = "    mode: "
    let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
    let matching = lines.indices.filter { lines[$0].hasPrefix(prefix) }
    guard matching.count == 1,
      lines[matching[0]] == prefix + "read-only"
    else {
      throw DeepSeekHarnessACPError.templateMismatch
    }
    let mode = permissionMode(for: mutationIntent)
    guard mode != "danger-full-access" else {
      throw DeepSeekHarnessACPError.templateMismatch
    }
    var updated = lines.map(String.init)
    updated[matching[0]] = prefix + mode
    value = updated.joined(separator: "\n")
    return Data(value.utf8)
  }

}

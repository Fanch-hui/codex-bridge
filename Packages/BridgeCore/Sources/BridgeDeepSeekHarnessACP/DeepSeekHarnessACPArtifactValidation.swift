import BridgeAgentCore
import Foundation

enum DeepSeekHarnessACPArtifactValidator {
  static func resolveArtifacts(
    executablePath: String,
    configurationPath: String,
    configurationTemplate: Data,
    sourceEnvironment: [String: String]
  ) throws -> [AgentInstallationArtifactRole: String] {
    let executable = try DeepSeekHarnessACPArtifactRuntime.canonicalPath(
      executablePath,
      field: "launch.executable"
    )
    let configuration = try DeepSeekHarnessACPArtifactRuntime.canonicalPath(
      configurationPath,
      field: "launch.configuration"
    )
    let configurationData = try DeepSeekHarnessACPArtifactRuntime.boundedData(
      at: configuration,
      maximumBytes: DeepSeekHarnessACPConstants.maximumFinalTextBytes,
      field: "launch_configuration.size"
    )
    _ = try DeepSeekHarnessACPModelCatalog.profile(
      configuration: configurationData,
      template: configurationTemplate
    )
    if let layout = DeepSeekHarnessACPRuntimeLayout.desktop(at: executable) {
      return [.launchConfiguration: configuration, .nodeInterpreter: layout.runtimePath]
    }
    let sourceRoot = try DeepSeekHarnessACPArtifactRuntime.findSourceRoot(
      startingAt: executable
    )
    guard let configurationRoot = AgentPathSemantics.directoryPath(of: configuration),
      !AgentPathSemantics.isContained(configurationRoot, in: sourceRoot)
    else {
      throw DeepSeekHarnessACPError.artifactInvalid("configuration.external_profile")
    }
    let node = try DeepSeekHarnessACPArtifactRuntime.findNodeInterpreter(
      executablePath: executable,
      sourceEnvironment: sourceEnvironment
    )
    var paths: [AgentInstallationArtifactRole: String] = [
      .launchConfiguration: configuration,
      .runtimeManifest: try DeepSeekHarnessACPPathSupport.append("package.json", to: sourceRoot),
      .nodeInterpreter: node,
    ]
    if let lock = try? DeepSeekHarnessACPArtifactRuntime.dependencyLockPath(in: sourceRoot) {
      paths[.dependencyLock] = lock
    } else if !DeepSeekHarnessACPArtifactRuntime.isPublishedPackage(executable) {
      throw DeepSeekHarnessACPError.artifactInvalid("dependency_lock")
    }
    let artifacts = try paths.map { role, path in
      makeArtifact(
        role: role,
        snapshot: try DeepSeekHarnessACPFileSnapshot(
          capturing: path,
          requiresExecutable: role.requiresExecutable))
    }
    let installation = try AgentInstallation(
      id: AgentInstallationID(rawValue: "deepseek-registration-probe"),
      providerID: .deepSeekHarness, executablePath: executable, artifacts: artifacts)
    _ = try validate(installation, configurationTemplate: configurationTemplate)
    return paths
  }

  static func validate(
    _ installation: AgentInstallation,
    configurationTemplate: Data
  ) throws -> DeepSeekHarnessACPValidatedInstallation {
    guard installation.providerID == .deepSeekHarness else {
      throw AgentRuntimeError.providerUnavailable(installation.providerID)
    }
    if let layout = DeepSeekHarnessACPRuntimeLayout.desktop(at: installation.executablePath) {
      return try DeepSeekHarnessACPDesktopArtifacts.validate(
        installation,
        configurationTemplate: configurationTemplate, layout: layout)
    }
    let artifacts = try requiredArtifacts(from: installation)
    let configuration = try validateArtifact(
      artifacts[.launchConfiguration]!,
      role: .launchConfiguration
    )
    guard configuration.fileSize <= DeepSeekHarnessACPConstants.maximumFinalTextBytes else {
      throw DeepSeekHarnessACPError.templateMismatch
    }
    let configurationData = try DeepSeekHarnessACPArtifactRuntime.boundedData(
      at: configuration.path,
      maximumBytes: DeepSeekHarnessACPConstants.maximumFinalTextBytes,
      field: "launch_configuration.size"
    )
    _ = try DeepSeekHarnessACPModelCatalog.profile(
      configuration: configurationData,
      template: configurationTemplate
    )

    let manifest = try validateArtifact(
      artifacts[.runtimeManifest]!,
      role: .runtimeManifest
    )
    let lock = try artifacts[.dependencyLock].map {
      try validateArtifact($0, role: .dependencyLock)
    }
    let node = try validateArtifact(artifacts[.nodeInterpreter]!, role: .nodeInterpreter)
    let sourceRoot: String
    if let lock {
      sourceRoot = try DeepSeekHarnessACPArtifactRuntime.commonSourceRoot(manifest.path, lock.path)
    } else {
      sourceRoot = URL(fileURLWithPath: manifest.path).deletingLastPathComponent().path
      let packageEntry = URL(fileURLWithPath: sourceRoot).appendingPathComponent("lib/bin.js").path
      guard DeepSeekHarnessACPArtifactRuntime.isPublishedPackage(packageEntry),
        DeepSeekHarnessACPPathSupport.samePath(packageEntry, installation.executablePath)
      else {
        throw DeepSeekHarnessACPError.artifactInvalid("dependency_lock")
      }
    }
    guard let configurationRoot = AgentPathSemantics.directoryPath(of: configuration.path),
      !AgentPathSemantics.isContained(configurationRoot, in: sourceRoot)
    else {
      throw DeepSeekHarnessACPError.artifactInvalid("configuration.external_profile")
    }
    let executable = try validateExecutable(
      installation.executablePath,
      sourceRoot: sourceRoot
    )
    _ = try DeepSeekHarnessACPArtifactRuntime.parseManifest(at: manifest.path)
    let nodeVersion = try DeepSeekHarnessACPArtifactRuntime.nodeVersion(at: node.path)
    guard DeepSeekHarnessACPArtifactRuntime.isCompatibleNodeVersion(nodeVersion) else {
      throw DeepSeekHarnessACPError.nodeVersionIncompatible(nodeVersion)
    }

    return DeepSeekHarnessACPValidatedInstallation(
      installation: installation,
      nodeInterpreterPath: node.path,
      executablePath: executable,
      configurationPath: configuration.path,
      configurationData: configurationData,
      sourceRoot: sourceRoot,
      nodeVersion: nodeVersion
    )
  }

  static func validatedConfigurationData(
    for installation: AgentInstallation,
    configurationTemplate: Data
  ) throws -> Data {
    guard installation.providerID == .deepSeekHarness else {
      throw AgentRuntimeError.providerUnavailable(installation.providerID)
    }
    let artifacts = Dictionary(uniqueKeysWithValues: installation.artifacts.map { ($0.role, $0) })
    guard artifacts[.launchConfiguration] != nil else {
      throw DeepSeekHarnessACPError.artifactInvalid("launch_configuration")
    }
    let configuration = try validateArtifact(
      artifacts[.launchConfiguration]!,
      role: .launchConfiguration
    )
    guard configuration.fileSize <= DeepSeekHarnessACPConstants.maximumFinalTextBytes else {
      throw DeepSeekHarnessACPError.templateMismatch
    }
    let data = try DeepSeekHarnessACPArtifactRuntime.boundedData(
      at: configuration.path,
      maximumBytes: DeepSeekHarnessACPConstants.maximumFinalTextBytes,
      field: "launch_configuration.size"
    )
    _ = try DeepSeekHarnessACPModelCatalog.profile(
      configuration: data,
      template: configurationTemplate
    )
    return data
  }

  private static func requiredArtifacts(
    from installation: AgentInstallation
  ) throws -> [AgentInstallationArtifactRole: AgentInstallationArtifact] {
    let expected =
      DeepSeekHarnessACPArtifactRuntime.isPublishedPackage(installation.executablePath)
      ? Set([AgentInstallationArtifactRole.launchConfiguration, .runtimeManifest, .nodeInterpreter])
      : Set(AgentInstallationArtifactRole.allCases)
    let actual = Set(installation.artifacts.map(\.role))
    guard expected.isSubset(of: actual), actual.count == installation.artifacts.count else {
      throw DeepSeekHarnessACPError.artifactInvalid("required_roles")
    }
    return Dictionary(uniqueKeysWithValues: installation.artifacts.map { ($0.role, $0) })
  }

  static func validateArtifact(
    _ artifact: AgentInstallationArtifact,
    role: AgentInstallationArtifactRole
  ) throws -> DeepSeekHarnessACPFileSnapshot {
    guard artifact.role == role,
      AgentPathSemantics.isAbsolute(artifact.canonicalPath),
      !artifact.canonicalPath.contains("\0"),
      artifact.canonicalPath.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw DeepSeekHarnessACPError.artifactInvalid(role.rawValue)
    }
    let path = URL(fileURLWithPath: artifact.canonicalPath)
      .resolvingSymlinksInPath()
      .standardizedFileURL
      .path
    guard DeepSeekHarnessACPPathSupport.samePath(path, artifact.canonicalPath) else {
      throw DeepSeekHarnessACPError.artifactInvalid("\(role.rawValue).canonical_path")
    }
    let snapshot = try DeepSeekHarnessACPFileSnapshot(
      capturing: path,
      requiresExecutable: role.requiresExecutable
    )
    guard snapshot.device == artifact.device,
      snapshot.inode == artifact.inode,
      snapshot.fileSize == artifact.fileSize,
      snapshot.modificationTimeNanoseconds == artifact.modificationTimeNanoseconds,
      snapshot.sha256 == artifact.sha256
    else {
      throw DeepSeekHarnessACPError.artifactInvalid("\(role.rawValue).identity")
    }
    return snapshot
  }

  private static func validateExecutable(_ path: String, sourceRoot: String) throws -> String {
    let canonical = try DeepSeekHarnessACPArtifactRuntime.canonicalPath(
      path,
      field: "launch.executable"
    )
    guard AgentPathSemantics.isAbsolute(canonical), !canonical.contains("\0") else {
      throw DeepSeekHarnessACPError.artifactInvalid("launch.executable")
    }
    guard AgentPathSemantics.isContained(canonical, in: sourceRoot) else {
      throw DeepSeekHarnessACPError.artifactInvalid("launch.executable.source_root")
    }
    _ = try DeepSeekHarnessACPFileSnapshot(
      capturing: canonical,
      requiresExecutable: DeepSeekHarnessACPArtifactRuntime.launchEntryRequiresNativeExecutable
    )
    return canonical
  }

  private static func makeArtifact(
    role: AgentInstallationArtifactRole,
    snapshot: DeepSeekHarnessACPFileSnapshot
  ) -> AgentInstallationArtifact {
    AgentInstallationArtifact(
      role: role,
      canonicalPath: snapshot.path,
      device: snapshot.device,
      inode: snapshot.inode,
      fileSize: snapshot.fileSize,
      modificationTimeNanoseconds: snapshot.modificationTimeNanoseconds,
      sha256: snapshot.sha256
    )
  }
}

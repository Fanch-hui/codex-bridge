import BridgeAgentCore
import Foundation

extension DeepSeekHarnessACPProvider: AgentInstallationRuntimeArtifactProviding {
  public func installationRuntimeArtifacts(for installation: AgentInstallation) async throws
    -> [AgentInstallationRuntimeArtifact]
  {
    try DeepSeekHarnessACPDesktopArtifacts.capture(executablePath: installation.executablePath)
  }
}

enum DeepSeekHarnessACPDesktopArtifacts {
  static func capture(executablePath: String) throws -> [AgentInstallationRuntimeArtifact] {
    guard let layout = DeepSeekHarnessACPRuntimeLayout.desktop(at: executablePath),
      let archivePath = layout.archivePath
    else { return [] }
    let archive = try DeepSeekHarnessACPArchive(path: archivePath)
    let paths = [archivePath] + archive.unpackedPaths().map { archivePath + ".unpacked/" + $0 }
    return try paths.map { path in
      let snapshot = try DeepSeekHarnessACPFileSnapshot(capturing: path, requiresExecutable: false)
      return AgentInstallationRuntimeArtifact(
        role: path == archivePath ? .archive : .unpackedFile,
        canonicalPath: snapshot.path, device: snapshot.device, inode: snapshot.inode,
        fileSize: snapshot.fileSize,
        modificationTimeNanoseconds: snapshot.modificationTimeNanoseconds,
        sha256: snapshot.sha256)
    }
  }

  static func validate(
    _ installation: AgentInstallation, configurationTemplate: Data,
    layout: DeepSeekHarnessACPRuntimeLayout
  ) throws -> DeepSeekHarnessACPValidatedInstallation {
    guard try capture(executablePath: installation.executablePath) == installation.runtimeArtifacts,
      !installation.runtimeArtifacts.isEmpty,
      let config = installation.artifacts.first(where: { $0.role == .launchConfiguration }),
      let runtime = installation.artifacts.first(where: { $0.role == .nodeInterpreter })
    else { throw DeepSeekHarnessACPError.artifactInvalid("desktop.identity") }
    let configuration = try DeepSeekHarnessACPArtifactValidator.validateArtifact(
      config, role: .launchConfiguration)
    let node = try DeepSeekHarnessACPArtifactValidator.validateArtifact(
      runtime, role: .nodeInterpreter)
    guard DeepSeekHarnessACPPathSupport.samePath(node.path, layout.runtimePath),
      DeepSeekHarnessACPPathSupport.samePath(installation.executablePath, layout.runtimePath),
      let archivePath = layout.archivePath,
      let resources = AgentPathSemantics.directoryPath(of: archivePath),
      !AgentPathSemantics.isContained(configuration.path, in: resources)
    else { throw DeepSeekHarnessACPError.artifactInvalid("desktop.pair") }
    let data = try DeepSeekHarnessACPArtifactRuntime.boundedData(
      at: configuration.path,
      maximumBytes: DeepSeekHarnessACPConstants.maximumFinalTextBytes,
      field: "launch_configuration.size")
    _ = try DeepSeekHarnessACPModelCatalog.profile(
      configuration: data, template: configurationTemplate)
    let version = try DeepSeekHarnessACPArtifactRuntime.nodeVersion(at: node.path, electron: true)
    guard DeepSeekHarnessACPArtifactRuntime.isCompatibleNodeVersion(version) else {
      throw DeepSeekHarnessACPError.nodeVersionIncompatible(version)
    }
    return DeepSeekHarnessACPValidatedInstallation(
      installation: installation,
      nodeInterpreterPath: node.path, executablePath: layout.runtimePath,
      configurationPath: configuration.path, configurationData: data,
      sourceRoot: resources, nodeVersion: version, runtimeLayout: layout)
  }
}

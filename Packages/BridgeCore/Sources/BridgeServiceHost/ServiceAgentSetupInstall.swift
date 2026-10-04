import BridgeAgentCore
import BridgeOpenCodeACP
import Foundation

public struct ServiceAgentSetupInstaller: ServiceAgentSetupInstalling {
  let io: any ServiceAgentSetupInstallIO
  let platform: ServiceAgentSetupInstallPlatform
  let sourceEnvironment: [String: String]

  public init() {
    self.init(
      io: ServiceAgentSetupInstallSystemIO(), platform: .current,
      environment: ProcessInfo.processInfo.environment)
  }

  init(
    io: any ServiceAgentSetupInstallIO, platform: ServiceAgentSetupInstallPlatform,
    environment: [String: String]
  ) {
    self.io = io
    self.platform = platform
    sourceEnvironment = environment
  }

  public func prepare(
    providerID: AgentProviderID, distribution: QoderDistribution?, root: URL,
    existingExecutable: String?, report: @escaping @Sendable (String) async -> Void
  ) async throws -> ServiceAgentSetupRuntime {
    try platform.checkSupport(providerID: providerID)
    try Task.checkCancellation()
    guard root.isFileURL, AgentPathSemantics.isAbsolute(root.path) else {
      throw ServiceAgentSetupInstallError.invalidMetadata("installation directory")
    }
    var group = root.appendingPathComponent(
      providerID == .qoder
        ? "qoder-\((distribution ?? .international).rawValue)" : providerID.rawValue)
    try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
    group = group.resolvingSymlinksInPath().standardizedFileURL
    try removeInterruptedStages(in: group)
    defer { removeIfPresent(group.appendingPathComponent(".scratch")) }
    await report("检查现有安装")
    if let existingExecutable,
      let reused = try await reuse(
        existingExecutable, providerID: providerID, distribution: distribution, group: group,
        report: report)
    {
      return reused
    }
    if let installed = try await cachedRuntime(in: group, providerID: providerID) {
      return installed
    }

    await report("安装程序和依赖")
    return try await stagedInstall(in: group) { stage in
      if [.openCode, .antigravity].contains(providerID) {
        return try await installBinary(providerID: providerID, in: stage)
      }
      await report("准备 Node 运行时")
      let node: String
      if let existingNode = await reusableNode(
        near: stage.appendingPathComponent("node").path, cwd: stage),
        (try? npmEntry(near: existingNode)) != nil
      {
        node = existingNode
      } else {
        node = try await installNode(in: stage)
      }
      await report("安装官方 Agent 包")
      let runtime = try await installNPM(
        providerID: providerID, distribution: distribution, in: stage, node: node)
      await report("正在保存安装结果")
      return runtime
    }
  }

  private func removeInterruptedStages(in group: URL) throws {
    let entries = try FileManager.default.contentsOfDirectory(
      at: group, includingPropertiesForKeys: nil)
    for entry in entries {
      let name = entry.lastPathComponent
      guard name.hasPrefix(".install-"), UUID(uuidString: String(name.dropFirst(9))) != nil else {
        continue
      }
      try FileManager.default.removeItem(at: entry)
    }
  }

  private func reuse(
    _ path: String, providerID: AgentProviderID, distribution: QoderDistribution?, group: URL,
    report: @escaping @Sendable (String) async -> Void
  ) async throws -> ServiceAgentSetupRuntime? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let entry = normalizeExisting(path, providerID: providerID, distribution: distribution)
    guard let entry else { return nil }
    let isNode = ["js", "cjs", "mjs"].contains(
      URL(fileURLWithPath: entry).pathExtension.lowercased())
    if !isNode, providerID != .qoder {
      guard
        let output = try? await io.run(
          [entry, "--version"], cwd: group, environment: installEnvironment(in: group))
      else {
        try Task.checkCancellation()
        return nil
      }
      let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
      if providerID == .openCode, !OpenCodeACPCompatibility().accepts(version: version) {
        return nil
      }
      return ServiceAgentSetupRuntime(
        executablePath: entry, version: version,
        installationDirectory: URL(fileURLWithPath: entry).deletingLastPathComponent().path)
    }
    let node = await reusableNode(near: entry, cwd: group)
    let sdk = providerID == .qoder ? existingSDK(near: entry, distribution: distribution) : nil
    if let node, providerID != .qoder || sdk != nil,
      let output = try? await io.run(
        versionArguments(executable: entry, node: node), cwd: group,
        environment: installEnvironment(in: group, node: node))
    {
      return ServiceAgentSetupRuntime(
        executablePath: entry, nodeExecutablePath: node, sdkRoot: sdk,
        version: output.trimmingCharacters(in: .whitespacesAndNewlines),
        installationDirectory: URL(fileURLWithPath: entry).deletingLastPathComponent().path)
    }
    try Task.checkCancellation()
    await report("补齐 Node 和 SDK 依赖")
    return try await stagedInstall(in: group) { stage in
      let preparedNode: String
      if let node, providerID != .qoder || (try? npmEntry(near: node)) != nil {
        preparedNode = node
      } else {
        preparedNode = try await installNode(in: stage)
      }
      if providerID == .qoder, sdk == nil {
        return try await installNPM(
          providerID: providerID, distribution: distribution, in: stage, node: preparedNode,
          existingExecutable: entry)
      }
      let output = try await io.run(
        versionArguments(executable: entry, node: preparedNode), cwd: stage,
        environment: installEnvironment(in: stage, node: preparedNode))
      return ServiceAgentSetupRuntime(
        executablePath: entry, nodeExecutablePath: preparedNode, sdkRoot: sdk,
        version: output.trimmingCharacters(in: .whitespacesAndNewlines),
        installationDirectory: stage.path)
    }
  }

  private func normalizeExisting(
    _ path: String, providerID: AgentProviderID, distribution: QoderDistribution?
  ) -> String? {
    if providerID == .qoder {
      return try? ServiceAgentAutoDiscovery.qoderExecutablePath(
        path, distribution: distribution ?? .international)
    }
    let entry = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    guard ["cmd", "bat"].contains(entry.pathExtension.lowercased()) else { return entry.path }
    var directory = entry.deletingLastPathComponent()
    var packages = ServiceAgentSetupInstallPackage.packages(
      providerID: providerID, distribution: distribution)
    if providerID == .pi {
      packages.append(
        ServiceAgentSetupInstallPackage(name: "@mariozechner/pi-coding-agent", command: "pi"))
    }
    for _ in 0..<8 {
      for package in packages {
        if let resolved = try? packageEntry(package, prefix: directory) { return resolved }
      }
      let parent = directory.deletingLastPathComponent()
      if parent.path == directory.path { break }
      directory = parent
    }
    return nil
  }

  private func stagedInstall(
    in group: URL, install: (URL) async throws -> ServiceAgentSetupRuntime
  ) async throws -> ServiceAgentSetupRuntime {
    let identifier = UUID().uuidString
    let stage = group.appendingPathComponent(".install-" + identifier)
    let destination = group.appendingPathComponent(identifier)
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
    defer { removeIfPresent(stage) }
    let runtime = try await install(stage)
    try Task.checkCancellation()
    // All managed paths move together; absolute npm entries never rely on the global PATH.
    func relocated(_ path: String?) -> String? {
      guard let path, AgentPathSemantics.isContained(path, in: stage.path) else { return path }
      return destination.path + String(path.dropFirst(stage.path.count))
    }
    let published = ServiceAgentSetupRuntime(
      executablePath: relocated(runtime.executablePath)!,
      nodeExecutablePath: relocated(runtime.nodeExecutablePath),
      sdkRoot: relocated(runtime.sdkRoot),
      version: runtime.version, installationDirectory: destination.path)
    let receipt = ServiceAgentSetupInstallReceipt(
      platform: platform.os + "-" + platform.architecture, runtime: published)
    try JSONEncoder().encode(receipt).write(
      to: stage.appendingPathComponent("runtime.json"), options: .atomic)
    removeIfPresent(stage.appendingPathComponent(".scratch"))
    try FileManager.default.moveItem(at: stage, to: destination)
    return published
  }

  private func cachedRuntime(in group: URL, providerID: AgentProviderID) async throws
    -> ServiceAgentSetupRuntime?
  {
    let children = try FileManager.default.contentsOfDirectory(
      at: group, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    for directory in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      guard let data = try? Data(contentsOf: directory.appendingPathComponent("runtime.json")),
        let receipt = try? JSONDecoder().decode(ServiceAgentSetupInstallReceipt.self, from: data),
        receipt.platform == platform.os + "-" + platform.architecture,
        URL(fileURLWithPath: receipt.runtime.installationDirectory).resolvingSymlinksInPath().path
          == directory.resolvingSymlinksInPath().path,
        FileManager.default.fileExists(atPath: receipt.runtime.executablePath)
      else { continue }
      let runtime = receipt.runtime
      let argv = versionArguments(
        executable: runtime.executablePath, node: runtime.nodeExecutablePath)
      if let version = try? await io.run(
        argv, cwd: group,
        environment: installEnvironment(in: group, node: runtime.nodeExecutablePath)),
        providerID != .openCode
          || OpenCodeACPCompatibility().accepts(
            version: version.trimmingCharacters(in: .whitespacesAndNewlines))
      {
        return runtime
      }
      try Task.checkCancellation()
    }
    return nil
  }

  func versionArguments(executable: String, node: String?) -> [String] {
    let isScript = ["js", "cjs", "mjs"].contains(
      URL(fileURLWithPath: executable).pathExtension.lowercased())
    if isScript, let node { return [node, executable, "--version"] }
    return [executable, "--version"]
  }

  private func removeIfPresent(_ path: URL) {
    guard FileManager.default.fileExists(atPath: path.path) else { return }
    try? FileManager.default.removeItem(at: path)
  }
}

private struct ServiceAgentSetupInstallReceipt: Codable {
  let platform: String
  let runtime: ServiceAgentSetupRuntime
}

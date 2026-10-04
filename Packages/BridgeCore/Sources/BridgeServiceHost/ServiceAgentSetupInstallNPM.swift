import BridgeAgentCore
import Foundation

struct ServiceAgentSetupInstallPackage: Equatable, Sendable {
  let name: String
  let command: String?

  static func packages(providerID: AgentProviderID, distribution: QoderDistribution?) -> [Self] {
    switch providerID {
    case .deepSeekHarness: [Self(name: "@deepseek-ai/dsh", command: "dsh")]
    case .pi: [Self(name: "@earendil-works/pi-coding-agent", command: "pi")]
    case .qoder:
      distribution == .cn
        ? [
          Self(name: "@qodercn-ai/qoderclicn", command: "qoderclicn"),
          Self(name: "@qodercn-ai/qodercn-agent-sdk", command: nil),
        ]
        : [
          Self(name: "@qoder-ai/qodercli", command: "qodercli"),
          Self(name: "@qoder-ai/qoder-agent-sdk", command: nil),
        ]
    default: []
    }
  }
}

extension ServiceAgentSetupInstaller {
  func installNPM(
    providerID: AgentProviderID, distribution: QoderDistribution?, in directory: URL,
    node: String, existingExecutable: String? = nil
  ) async throws -> ServiceAgentSetupRuntime {
    let packages = ServiceAgentSetupInstallPackage.packages(
      providerID: providerID, distribution: distribution)
    let required = existingExecutable == nil ? packages : packages.filter { $0.command == nil }
    var versions: [String: String] = [:]
    var integrities: [String: String] = [:]
    var specifications: [String] = []
    for package in required {
      let encoded = package.name.replacingOccurrences(of: "/", with: "%2f")
      let metadata = try await object(URL(string: "https://registry.npmjs.org/\(encoded)/latest")!)
      guard metadata["name"] as? String == package.name,
        let version = metadata["version"] as? String, !version.isEmpty,
        let dist = metadata["dist"] as? [String: Any],
        let integrity = dist["integrity"] as? String, integrity.hasPrefix("sha512-")
      else { throw ServiceAgentSetupInstallError.invalidMetadata(package.name) }
      versions[package.name] = version
      integrities[package.name] = integrity
      specifications.append(package.name + "@" + version)
    }
    if !specifications.isEmpty {
      let npm = try npmEntry(near: node)
      _ = try await io.run(
        [
          node, npm, "install", "--prefix", directory.path, "--no-audit", "--no-fund",
          "--engine-strict", "--registry", "https://registry.npmjs.org",
        ] + specifications,
        cwd: directory, environment: installEnvironment(in: directory, node: node))
      try verifyPackageLock(directory, expected: versions, integrities: integrities)
    }
    guard let cli = packages.first else {
      throw ServiceAgentSetupInstallError.unavailableExecutable
    }
    let entry = try existingExecutable ?? packageEntry(cli, prefix: directory)
    let output = try await io.run(
      versionArguments(executable: entry, node: node), cwd: directory,
      environment: installEnvironment(in: directory, node: node))
    let sdk = packages.first(where: { $0.command == nil }).map {
      directory.appendingPathComponent("node_modules/" + $0.name).path
    }
    return ServiceAgentSetupRuntime(
      executablePath: entry, nodeExecutablePath: node, sdkRoot: sdk,
      version: versions[cli.name] ?? output.trimmingCharacters(in: .whitespacesAndNewlines),
      installationDirectory: directory.path)
  }

  func packageEntry(_ package: ServiceAgentSetupInstallPackage, prefix: URL) throws -> String {
    let root = prefix.appendingPathComponent("node_modules/" + package.name)
    let data = try Data(contentsOf: root.appendingPathComponent("package.json"))
    guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      manifest["name"] as? String == package.name
    else { throw ServiceAgentSetupInstallError.invalidMetadata(package.name) }
    let relative: String?
    if let mapping = manifest["bin"] as? [String: String], let command = package.command {
      relative = mapping[command]
    } else {
      relative = manifest["bin"] as? String
    }
    guard let relative, !AgentPathSemantics.isAbsolute(relative), !relative.contains("\0") else {
      throw ServiceAgentSetupInstallError.invalidMetadata(package.name + " entry")
    }
    let canonical = root.appendingPathComponent(relative).resolvingSymlinksInPath()
    guard AgentPathSemantics.isContained(canonical.path, in: root.resolvingSymlinksInPath().path),
      FileManager.default.fileExists(atPath: canonical.path)
    else { throw ServiceAgentSetupInstallError.unavailableExecutable }
    return canonical.path
  }

  func existingSDK(near executable: String, distribution: QoderDistribution?) -> String? {
    let name = distribution == .cn ? "@qodercn-ai/qodercn-agent-sdk" : "@qoder-ai/qoder-agent-sdk"
    var directory = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
      .deletingLastPathComponent()
    for _ in 0..<8 {
      let candidate = directory.appendingPathComponent("node_modules/" + name)
      if let data = try? Data(contentsOf: candidate.appendingPathComponent("package.json")),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        object["name"] as? String == name
      {
        return candidate.path
      }
      let parent = directory.deletingLastPathComponent()
      if parent.path == directory.path { break }
      directory = parent
    }
    return nil
  }

  func npmEntry(near node: String) throws -> String {
    let parent = URL(fileURLWithPath: node).deletingLastPathComponent()
    let candidates = [
      parent.appendingPathComponent("node_modules/npm/bin/npm-cli.js"),
      parent.deletingLastPathComponent().appendingPathComponent(
        "lib/node_modules/npm/bin/npm-cli.js"),
    ]
    guard let entry = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    else {
      throw ServiceAgentSetupInstallError.commandFailed("npm 运行时缺失")
    }
    return entry.path
  }

  private func verifyPackageLock(
    _ directory: URL, expected: [String: String], integrities: [String: String]
  ) throws {
    let data = try Data(contentsOf: directory.appendingPathComponent("package-lock.json"))
    guard let lock = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let packages = lock["packages"] as? [String: [String: Any]]
    else { throw ServiceAgentSetupInstallError.invalidMetadata("npm lock") }
    for (name, version) in expected {
      let relative = "node_modules/" + name
      let expectedPath = directory.appendingPathComponent(relative).resolvingSymlinksInPath().path
      // npm can record paths relative to a different spelling of a symlinked prefix.
      let item =
        packages[relative]
        ?? packages.first {
          directory.appendingPathComponent($0.key).resolvingSymlinksInPath().path == expectedPath
        }?.value
      guard let item, item["version"] as? String == version,
        item["integrity"] as? String == integrities[name]
      else { throw ServiceAgentSetupInstallError.invalidMetadata("npm integrity") }
    }
  }
}

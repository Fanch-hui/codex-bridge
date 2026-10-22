import BridgeAgentCore
import Foundation

extension ServiceAgentSetupInstaller {
  func installBinary(providerID: AgentProviderID, in directory: URL) async throws
    -> ServiceAgentSetupRuntime
  {
    if providerID == .antigravity { return try await installAntigravity(in: directory) }
    let name = "@opencode/cli"
    let metadata = try await object(
      URL(string: "https://registry.npmjs.org/@opencode%2fcli/latest")!)
    let package = platform.openCodePackageName
    guard metadata["name"] as? String == name,
      let version = metadata["version"] as? String, !version.isEmpty,
      let dependencies = metadata["optionalDependencies"] as? [String: String],
      dependencies[package] == version
    else { throw ServiceAgentSetupInstallError.invalidMetadata("OpenCode distribution") }
    let encodedPackage = package.replacingOccurrences(of: "/", with: "%2f")
    let artifact = try await object(
      URL(string: "https://registry.npmjs.org/\(encodedPackage)/\(version)")!)
    guard artifact["name"] as? String == package, artifact["version"] as? String == version,
      let dist = artifact["dist"] as? [String: Any],
      let download = dist["tarball"] as? String,
      let integrity = dist["integrity"] as? String, integrity.hasPrefix("sha512-"),
      let digest = Data(base64Encoded: String(integrity.dropFirst(7))), digest.count == 64
    else { throw ServiceAgentSetupInstallError.invalidMetadata("OpenCode package") }
    let archive = directory.appendingPathComponent("opencode.tgz")
    defer { try? FileManager.default.removeItem(at: archive) }
    try await io.download(
      officialURL(download, allowedHosts: ["registry.npmjs.org"]), to: archive)
    try ServiceAgentSetupInstallIntegrity.verify(
      archive, digest: digest.map { String(format: "%02x", $0) }.joined(), algorithm: "sha512")
    try await extract(archive, into: directory)
    let entry = try executable(
      directory.appendingPathComponent("package/bin/opencode" + platform.executableSuffix))
    _ = try await io.run(
      [entry, "--version"], cwd: directory, environment: installEnvironment(in: directory))
    return ServiceAgentSetupRuntime(
      executablePath: entry, version: version, installationDirectory: directory.path)
  }

  private func installAntigravity(in directory: URL) async throws -> ServiceAgentSetupRuntime {
    let base = "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app"
    let manifest = try await object(
      URL(string: base + "/manifests/" + platform.antigravityTarget + ".json")!)
    guard let download = manifest["url"] as? String,
      let digest = manifest["sha512"] as? String,
      let version = manifest["version"] as? String
    else { throw ServiceAgentSetupInstallError.invalidMetadata("Antigravity manifest") }
    let url = try officialURL(download, allowedHosts: ["run.app", "googleapis.com", "google.com"])
    let isArchive = url.path.hasSuffix(".tar.gz")
    let payload = directory.appendingPathComponent(
      isArchive ? "agy.tar.gz" : "agy" + platform.executableSuffix)
    try await io.download(url, to: payload)
    try ServiceAgentSetupInstallIntegrity.verify(payload, digest: digest, algorithm: "sha512")
    let entry: String
    if isArchive {
      defer { try? FileManager.default.removeItem(at: payload) }
      try await extract(payload, into: directory)
      let target = directory.appendingPathComponent("agy" + platform.executableSuffix)
      try FileManager.default.moveItem(
        at: directory.appendingPathComponent("antigravity" + platform.executableSuffix), to: target)
      entry = try executable(target)
    } else {
      entry = try executable(payload)
    }
    _ = try await io.run(
      [entry, "--version"], cwd: directory, environment: installEnvironment(in: directory))
    return ServiceAgentSetupRuntime(
      executablePath: entry, version: version, installationDirectory: directory.path)
  }
}

extension ServiceAgentSetupInstallPlatform {
  var openCodePackageName: String {
    // Baseline builds also support older x64 CPUs, including Intel Macs without AVX2.
    let baseline = architecture == "x64" ? "-baseline" : ""
    return "@opencode/cli-\(os)-\(architecture)\(baseline)"
  }
}

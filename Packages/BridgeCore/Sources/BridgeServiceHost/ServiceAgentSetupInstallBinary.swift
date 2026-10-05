import BridgeAgentCore
import Foundation

extension ServiceAgentSetupInstaller {
  func installBinary(providerID: AgentProviderID, in directory: URL) async throws
    -> ServiceAgentSetupRuntime
  {
    if providerID == .antigravity { return try await installAntigravity(in: directory) }
    let release = try await object(
      URL(string: "https://api.github.com/repos/anomalyco/opencode/releases/latest")!)
    // Baseline builds also work on older x64 CPUs, including Intel Macs without AVX2.
    let baseline = platform.architecture == "x64" ? "-baseline" : ""
    let extensionName = platform.os == "linux" ? ".tar.gz" : ".zip"
    let filename = "opencode-\(platform.os)-\(platform.architecture)\(baseline)\(extensionName)"
    guard let assets = release["assets"] as? [[String: Any]],
      let asset = assets.first(where: { $0["name"] as? String == filename }),
      let download = asset["browser_download_url"] as? String,
      let digest = asset["digest"] as? String, digest.hasPrefix("sha256:"),
      let version = release["tag_name"] as? String
    else { throw ServiceAgentSetupInstallError.invalidMetadata("OpenCode release") }
    let archive = directory.appendingPathComponent(filename)
    defer { try? FileManager.default.removeItem(at: archive) }
    try await io.download(
      officialURL(download, allowedHosts: ["github.com"]), to: archive)
    try ServiceAgentSetupInstallIntegrity.verify(
      archive, digest: String(digest.dropFirst(7)), algorithm: "sha256")
    try await extract(archive, into: directory)
    let entry = try executable(
      directory.appendingPathComponent("opencode" + platform.executableSuffix))
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

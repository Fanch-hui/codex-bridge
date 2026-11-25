import BridgeAgentCore
import Foundation

extension ServiceAgentSetupInstaller {
  func installClaudeBinary(in directory: URL) async throws -> ServiceAgentSetupRuntime {
    let name = "@anthropic-ai/claude-code"
    let metadata = try await object(
      URL(string: "https://registry.npmjs.org/@anthropic-ai%2fclaude-code/latest")!)
    let packageOS = platform.os == "windows" ? "win32" : platform.os
    let package = "\(name)-\(packageOS)-\(platform.architecture)"
    guard metadata["name"] as? String == name,
      let version = metadata["version"] as? String,
      version.range(
        of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$"#,
        options: .regularExpression) != nil,
      let dependencies = metadata["optionalDependencies"] as? [String: String],
      dependencies[package] == version
    else { throw ServiceAgentSetupInstallError.invalidMetadata("Claude Code distribution") }
    let encodedPackage = package.replacingOccurrences(of: "/", with: "%2f")
    let artifact = try await object(
      URL(string: "https://registry.npmjs.org/\(encodedPackage)/\(version)")!)
    guard artifact["name"] as? String == package, artifact["version"] as? String == version,
      let distribution = artifact["dist"] as? [String: Any],
      let download = distribution["tarball"] as? String,
      let integrity = distribution["integrity"] as? String, integrity.hasPrefix("sha512-"),
      let digest = Data(base64Encoded: String(integrity.dropFirst(7))), digest.count == 64
    else { throw ServiceAgentSetupInstallError.invalidMetadata("Claude Code package") }
    let archive = directory.appendingPathComponent("claude.tgz")
    defer { try? FileManager.default.removeItem(at: archive) }
    try await io.download(
      officialURL(download, allowedHosts: ["registry.npmjs.org"]), to: archive)
    try ServiceAgentSetupInstallIntegrity.verify(
      archive, digest: digest.map { String(format: "%02x", $0) }.joined(), algorithm: "sha512")
    try await extract(archive, into: directory)
    let entry = try executable(
      directory.appendingPathComponent("package/claude" + platform.executableSuffix))
    _ = try await io.run(
      [entry, "--version"], cwd: directory, environment: installEnvironment(in: directory))
    return ServiceAgentSetupRuntime(
      executablePath: entry, version: version, installationDirectory: directory.path)
  }
}

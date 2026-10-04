import BridgeAgentCore
import Foundation

struct ServiceAgentSetupInstallPlatform: Equatable, Sendable {
  let os: String
  let architecture: String

  static var current: Self {
    #if os(Windows)
      let os = "windows"
    #elseif os(macOS)
      let os = "darwin"
    #else
      let os = "linux"
    #endif
    #if arch(arm64)
      let architecture = "arm64"
    #else
      let architecture = "x64"
    #endif
    return Self(os: os, architecture: architecture)
  }

  var executableSuffix: String { os == "windows" ? ".exe" : "" }
  var nodeArchivePlatform: String { os == "windows" ? "win" : os }
  var antigravityTarget: String {
    "\(os)_\(architecture == "x64" ? "amd64" : architecture)"
  }

  func checkSupport(providerID: AgentProviderID) throws {
    guard [.openCode, .deepSeekHarness, .pi, .qoder, .antigravity].contains(providerID) else {
      throw ServiceAgentSetupInstallError.unsupported("此 Agent 不提供一键配置。")
    }
    if providerID == .qoder, os == "windows", architecture == "arm64" {
      throw ServiceAgentSetupInstallError.unsupported("Qoder 官方目前不支持 Windows ARM64。")
    }
  }
}

extension ServiceAgentSetupInstaller {
  func extract(_ archive: URL, into directory: URL) async throws {
    let tar = try tool("tar")
    let environment = installEnvironment(in: directory)
    let listing = try await io.run(
      [tar, "-tf", archive.path], cwd: directory, environment: environment)
    guard
      listing.split(whereSeparator: \.isNewline).allSatisfy({ entry in
        !entry.hasPrefix("/") && !entry.hasPrefix("\\")
          && !entry.contains(":") && !entry.split(separator: "/").contains("..")
          && !entry.split(separator: "\\").contains("..")
      })
    else { throw ServiceAgentSetupInstallError.invalidMetadata("archive") }
    _ = try await io.run(
      [tar, "-xf", archive.path, "-C", directory.path], cwd: directory,
      environment: environment)
  }

  func tool(_ name: String) throws -> String {
    var additional = ["/usr/bin", "/bin"]
    if let systemRoot = sourceEnvironment["SystemRoot"] ?? sourceEnvironment["WINDIR"] {
      additional.append(URL(fileURLWithPath: systemRoot).appendingPathComponent("System32").path)
    }
    guard
      let executable = AgentExecutableResolver(
        environment: sourceEnvironment, additionalDirectories: additional,
        preferredExtensions: [".exe"]
      ).resolve(name)
    else {
      throw ServiceAgentSetupInstallError.commandFailed("缺少 \(name)")
    }
    return executable
  }

  func installEnvironment(in directory: URL, node: String? = nil) -> [String: String] {
    let retained = [
      "HOME", "USERPROFILE", "SystemRoot", "WINDIR", "PATH", "LANG", "LC_ALL",
      "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY", "https_proxy", "http_proxy",
      "all_proxy", "no_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS",
    ]
    var environment = sourceEnvironment.filter { retained.contains($0.key) }
    let scratch = directory.appendingPathComponent(".scratch")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    environment["TMPDIR"] = scratch.path
    environment["TEMP"] = scratch.path
    environment["TMP"] = scratch.path
    environment["npm_config_cache"] = scratch.appendingPathComponent("npm-cache").path
    environment["npm_config_userconfig"] = scratch.appendingPathComponent("npmrc").path
    environment["npm_config_registry"] = "https://registry.npmjs.org"
    if let node {
      environment["PATH"] = AgentProviderEnvironment.executableSearchPath(
        executablePath: node, source: environment)
    }
    return environment
  }

  func executable(_ path: URL) throws -> String {
    let canonical = path.resolvingSymlinksInPath().standardizedFileURL
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &directory),
      !directory.boolValue
    else { throw ServiceAgentSetupInstallError.unavailableExecutable }
    if platform.os != "windows" {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: canonical.path)
    }
    return canonical.path
  }

  func object(_ url: URL) async throws -> [String: Any] {
    let bytes = try await io.fetch(url)
    guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
      throw ServiceAgentSetupInstallError.invalidMetadata(url.host ?? "JSON")
    }
    return value
  }

  func officialURL(_ value: String, allowedHosts: [String]) throws -> URL {
    guard let url = URL(string: value), url.scheme == "https", url.user == nil,
      url.password == nil, let host = url.host,
      allowedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
    else { throw ServiceAgentSetupInstallError.invalidMetadata("download URL") }
    return url
  }
}

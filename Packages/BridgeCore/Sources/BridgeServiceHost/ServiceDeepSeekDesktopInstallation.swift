import BridgeAgentCore
import BridgeDeepSeekHarnessACP
import BridgeDeepSeekHarnessDesktop
import BridgeSecurity
import Crypto
import Foundation

#if os(macOS)
  import AppKit
#endif

enum ServiceDeepSeekDesktopInstallError: Error, LocalizedError {
  case unsupportedPlatform
  case desktopInstallationRequired
  case desktopMustExit
  case installationFailed

  var errorDescription: String? {
    switch self {
    case .unsupportedPlatform: "此平台暂不支持 DSH 原生桌面安装。"
    case .desktopInstallationRequired: "请先安装官方 DSH Desktop，再安装连接器。"
    case .desktopMustExit: "请完全退出 DSH Desktop 后重试安装连接器。"
    case .installationFailed: "连接器安装失败。请先启动一次 DSH Desktop 完成初始化，再完全退出后重试。"
    }
  }
}

struct ServiceDeepSeekDesktopInstallation: Sendable {
  static var isSupported: Bool {
    #if os(macOS) || (os(Windows) && arch(x86_64))
      true
    #else
      false
    #endif
  }

  let root: URL
  let io: any ServiceAgentSetupInstallIO
  let environment: [String: String]

  init(
    paths: ServiceDataPaths,
    io: any ServiceAgentSetupInstallIO = ServiceAgentSetupInstallSystemIO(),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    root = paths.agentStateURL.appendingPathComponent("DSHDesktop", isDirectory: true)
    self.io = io
    self.environment = environment
  }

  func descriptorPath(for installationID: AgentInstallationID) -> String {
    installationRoot(installationID).appendingPathComponent("endpoint.json").path
  }

  func isInstalled(_ installation: AgentInstallation) -> Bool {
    guard
      let marker = try? SecureFileArtifactReader.read(
        at: installationRoot(installation.id).appendingPathComponent("installed.json").path,
        maximumBytes: 4 * 1_024),
      let value = try? JSONDecoder().decode(Receipt.self, from: marker),
      value.fingerprint == DSHDesktopRuntimeResources.fingerprint,
      value.executablePath == installation.executablePath
    else { return false }
    return true
  }

  func install(_ installation: AgentInstallation) async throws {
    #if os(macOS) || (os(Windows) && arch(x86_64))
      guard let layout = DeepSeekHarnessACPRuntimeLayout.desktop(at: installation.executablePath)
      else { throw ServiceDeepSeekDesktopInstallError.desktopInstallationRequired }
      guard try await !isRunning(layout) else {
        throw ServiceDeepSeekDesktopInstallError.desktopMustExit
      }
      let package = try preparePackage(installation)
      var launchEnvironment: [String: String] = [:]
      for name in [
        "HOME", "PATH", "DSH_HOME", "TMPDIR", "TMP", "TEMP", "HTTP_PROXY", "HTTPS_PROXY",
        "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
      ] {
        if let value = environment[name], !value.contains("\0"), value.utf8.count <= 32 * 1_024 {
          launchEnvironment[name] = value
        }
      }
      AgentProviderEnvironment.applyWindowsSystemEnvironment(
        to: &launchEnvironment, from: environment)
      launchEnvironment.merge(layout.environment) { _, value in value }
      do {
        _ = try await io.run(
          [layout.runtimePath] + layout.runtimeArguments
            + [layout.entryPath, "plugin", "--profile", "desktop", "add", package.path],
          cwd: package, environment: launchEnvironment)
      } catch is CancellationError { throw CancellationError() } catch {
        throw ServiceDeepSeekDesktopInstallError.installationFailed
      }
      let receipt = Receipt(
        fingerprint: DSHDesktopRuntimeResources.fingerprint,
        executablePath: installation.executablePath)
      try JSONEncoder().encode(receipt).write(
        to: installationRoot(installation.id).appendingPathComponent("installed.json"),
        options: .atomic)
    #else
      throw ServiceDeepSeekDesktopInstallError.unsupportedPlatform
    #endif
  }

  private func preparePackage(_ installation: AgentInstallation) throws -> URL {
    let source = try DSHDesktopRuntimeResources.validatedDirectory()
    let instance = installationRoot(installation.id)
    try ServiceDataPaths.preparePrivateDirectory(root, createParents: false)
    try ServiceDataPaths.preparePrivateDirectory(instance, createParents: false)
    let packages = instance.appendingPathComponent("Connector", isDirectory: true)
    try ServiceDataPaths.preparePrivateDirectory(packages, createParents: false)
    let package = packages.appendingPathComponent(
      DSHDesktopRuntimeResources.fingerprint, isDirectory: true)
    try ServiceDataPaths.preparePrivateDirectory(package, createParents: false)
    for name in DSHDesktopRuntimeResources.expectedDigests.keys.sorted() {
      let bytes = try SecureFileArtifactReader.read(
        at: source.appendingPathComponent(name).path,
        maximumBytes: 4 * 1_024 * 1_024)
      try bytes.write(to: package.appendingPathComponent(name), options: .atomic)
    }
    let path = String(
      decoding: try JSONEncoder().encode(descriptorPath(for: installation.id)), as: UTF8.self)
    let patch =
      "- insert:\n    - id: codex-bridge-dsh-desktop\n      name: '@codex-bridge/dsh-desktop-connector'\n      config:\n        descriptorPath: \(path)\n"
    try Data(patch.utf8).write(
      to: package.appendingPathComponent("cordis.patch.yml"), options: .atomic)
    return package
  }

  private func installationRoot(_ id: AgentInstallationID) -> URL {
    let hash = SHA256.hash(data: Data(id.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
    return root.appendingPathComponent(hash, isDirectory: true)
  }

  private func isRunning(_ layout: DeepSeekHarnessACPRuntimeLayout) async throws -> Bool {
    #if os(macOS)
      let runtime = URL(fileURLWithPath: layout.runtimePath)
      let bundle = runtime.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
      return await MainActor.run {
        NSWorkspace.shared.runningApplications.contains {
          $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == bundle
        }
      }
    #elseif os(Windows)
      return try WindowsProcessIdentity.hasOtherProcess(at: layout.runtimePath)
    #else
      return false
    #endif
  }

  private struct Receipt: Codable {
    let fingerprint: String
    let executablePath: String
  }
}

import BridgeProcess
import Foundation

public struct CommunityProviderCatalogEntry: Codable, Sendable {
  public let name: String
  public let package: String
  public let version: String
  public let license: String
  public let source: String
  public let verified: Bool
  public let accessMode: String?
  public let summary: String?
  public let requirements: String?
  public let environmentSetup: String?
  public let usageSteps: [String]?
  public let limitSummary: String?
  public let compatibility: String?
  public let compatibilityDetails: String?
  public let unavailableAuthMethods: [String]?
}

public struct CommunityProviderInstalledPackage: Decodable, Sendable {
  public let spec: String
  public let target: String
  public let license: String?
}

public enum CommunityProviderInstallationError: Error, LocalizedError, Sendable {
  case invalidDirectory
  case busy
  case unavailable
  case processStillRunning
  case failed(String)

  public var errorDescription: String? {
    switch self {
    case .invalidDirectory: "社区供应商目录无效。"
    case .busy: "社区供应商安装正在进行。"
    case .unavailable: "社区供应商安装程序不可用。"
    case .processStillRunning: "社区供应商安装进程尚未退出。"
    case .failed(let message): message
    }
  }
}

public actor CommunityProviderInstallation {
  private let resources: ProviderRuntimeResources
  private let directory: URL
  private var busy = false

  public init(resources: ProviderRuntimeResources, directory: URL) throws {
    guard directory.isFileURL, directory.path.hasPrefix("/") || directory.path.contains(":") else {
      throw CommunityProviderInstallationError.invalidDirectory
    }
    self.resources = resources
    self.directory = directory.standardizedFileURL
  }

  public func catalog() throws -> [CommunityProviderCatalogEntry] {
    try resources.validateEntrypoints()
    return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: resources.catalog))
      .providers
  }

  public func prepareBun() async throws -> URL {
    let result: Bun = try await run(Request(action: "prepareBun", root: directory.path))
    return URL(fileURLWithPath: result.path)
  }

  public func install(name: String, version: String) async throws
    -> CommunityProviderInstalledPackage
  {
    return try await run(
      Request(action: "install", root: directory.path, name: name, version: version))
  }

  public func remove(name: String) async throws {
    let _: Removal = try await run(Request(action: "remove", root: directory.path, name: name))
  }

  public func latestVersion(name: String) async throws -> String {
    let result: Latest = try await run(Request(action: "latest", root: directory.path, name: name))
    return result.version
  }

  private func run<Result: Decodable & Sendable>(_ request: Request) async throws -> Result {
    let modifiesInstallation = request.action != "latest"
    guard !modifiesInstallation || !busy else { throw CommunityProviderInstallationError.busy }
    if modifiesInstallation { busy = true }
    defer { if modifiesInstallation { busy = false } }
    try resources.validateEntrypoints()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let output = CommunityInstallationOutput()
    let inherited = ProcessInfo.processInfo.environment
    var environment = [
      "HOME": directory.path, "USERPROFILE": directory.path, "TMPDIR": directory.path,
      "TEMP": directory.path, "TMP": directory.path,
    ]
    #if os(Windows)
      if let windows = Self.windowsEnvironmentValue("SystemRoot", in: inherited)
        ?? Self.windowsEnvironmentValue("WINDIR", in: inherited)
      {
        environment["SystemRoot"] = windows
        environment["WINDIR"] = windows
        environment["PATH"] = "\(windows)\\System32;\(windows)"
      }
    #else
      environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    #endif
    let proxyKeys = [
      "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
      "http_proxy", "https_proxy", "all_proxy", "no_proxy",
    ]
    var hasProxy = false
    for key in proxyKeys {
      if let value = Self.validForwardedValue(key, in: inherited) {
        environment[key] = value
        hasProxy = true
      }
    }
    for key in ["NODE_USE_ENV_PROXY", "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS"] {
      if let value = Self.validForwardedValue(key, in: inherited) {
        environment[key] = value
      }
    }
    if hasProxy, environment["NODE_USE_ENV_PROXY"] == nil {
      environment["NODE_USE_ENV_PROXY"] = "1"
    }
    let process = try ManagedStdioProcess(
      argv: [resources.node.path, resources.installationEntry.path],
      workingDirectory: directory.path, environment: environment, mergeStandardError: false,
      onStandardOutput: { output.append($0) })
    return try await withTaskCancellationHandler {
      do {
        try Task.checkCancellation()
        try process.writeStdin(JSONEncoder().encode(request))
        process.closeStdin()
        let status = await ManagedProcessRunner(defaultTimeout: .seconds(600)).monitor(
          process: process)
        guard process.isProcessTreeStopped() else {
          throw CommunityProviderInstallationError.processStillRunning
        }
        try Task.checkCancellation()
        guard !status.timedOut,
          status.termination == .exited(0) || status.termination == .exited(1),
          let data = output.snapshot()
        else { throw CommunityProviderInstallationError.unavailable }
        let response = try JSONDecoder().decode(Response<Result>.self, from: data)
        if let message = response.error { throw CommunityProviderInstallationError.failed(message) }
        guard let result = response.result else {
          throw CommunityProviderInstallationError.unavailable
        }
        return result
      } catch {
        let stopped = await Task.detached { process.terminateProcessTreeAndWait() }.value
        guard stopped else {
          Self.retainUntilStopped(process)
          throw CommunityProviderInstallationError.processStillRunning
        }
        process.close()
        throw error
      }
    } onCancel: {
      process.terminateGroup()
    }
  }

  private static func windowsEnvironmentValue(
    _ name: String, in environment: [String: String]
  ) -> String? {
    if let value = environment[name], !value.isEmpty, !value.contains("\0") {
      return value
    }
    guard
      let key = environment.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }),
      let value = environment[key], !value.isEmpty, !value.contains("\0")
    else { return nil }
    return value
  }

  private static func validForwardedValue(
    _ name: String, in environment: [String: String]
  ) -> String? {
    #if os(Windows)
      windowsEnvironmentValue(name, in: environment)
    #else
      guard let value = environment[name], !value.isEmpty, !value.contains("\0") else {
        return nil
      }
      return value
    #endif
  }

  private static func retainUntilStopped(_ process: ManagedStdioProcess) {
    Task.detached {
      while !process.isProcessTreeStopped() { try? await Task.sleep(for: .seconds(1)) }
      process.close()
    }
  }

  private struct Catalog: Decodable { let providers: [CommunityProviderCatalogEntry] }
  private struct Bun: Decodable, Sendable {
    let path: String
    let version: String
  }
  private struct Removal: Decodable, Sendable { let removed: Bool }
  private struct Latest: Decodable, Sendable { let version: String }
  private struct Request: Encodable {
    let action: String
    let root: String
    var name: String? = nil
    var version: String? = nil
  }
  private struct Response<Result: Decodable>: Decodable {
    let result: Result?
    let error: String?
  }
}

private final class CommunityInstallationOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  private var exceeded = false

  func append(_ chunk: Data) {
    lock.withLock {
      guard data.count + chunk.count <= 64 * 1_024 else {
        exceeded = true
        return
      }
      data.append(chunk)
    }
  }

  func snapshot() -> Data? { lock.withLock { exceeded ? nil : data } }
}

import BridgeAgentCore
import BridgeProcess
import Crypto
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

protocol ServiceAgentSetupInstallIO: Sendable {
  func fetch(_ url: URL) async throws -> Data
  func download(_ url: URL, to destination: URL) async throws
  func run(
    _ argv: [String], cwd: URL, environment: [String: String], timeoutSeconds: Int64
  ) async throws -> String
}

extension ServiceAgentSetupInstallIO {
  func run(_ argv: [String], cwd: URL, environment: [String: String]) async throws -> String {
    try await run(
      argv, cwd: cwd, environment: environment,
      timeoutSeconds: argv.contains("--version")
        ? AgentSetupProcessLimits.maximumControlSeconds : AgentSetupProcessLimits.maximumRunSeconds)
  }
}

struct ServiceAgentSetupInstallSystemIO: ServiceAgentSetupInstallIO {
  func fetch(_ url: URL) async throws -> Data {
    var request = URLRequest(url: url)
    request.setValue("CodexBridge-AgentSetup", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 60
    let (bytes, response) = try await URLSession.shared.data(for: request)
    try validate(response)
    guard bytes.count <= 8 * 1_024 * 1_024 else {
      throw ServiceAgentSetupInstallError.invalidMetadata(url.host ?? "download")
    }
    return bytes
  }

  func download(_ url: URL, to destination: URL) async throws {
    var request = URLRequest(url: url)
    request.timeoutInterval = 600
    let (temporary, response) = try await URLSession.shared.download(for: request)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try validate(response)
    try Task.checkCancellation()
    try FileManager.default.moveItem(at: temporary, to: destination)
  }

  func run(
    _ argv: [String], cwd: URL, environment: [String: String], timeoutSeconds: Int64
  ) async throws -> String {
    let output = ServiceAgentSetupInstallOutput()
    let process: ManagedStdioProcess
    do {
      process = try ManagedStdioProcess(
        argv: argv, workingDirectory: cwd.path, environment: environment,
        mergeStandardError: true, onStandardOutput: { output.append($0) })
    } catch ManagedProcessError.processLaunchFailed(let status) {
      throw ServiceAgentSetupInstallError.commandFailed(
        URL(fileURLWithPath: argv[0]).lastPathComponent,
        diagnosticCode: "SPAWN_\(UInt32(bitPattern: status))")
    }
    process.closeStdin()
    defer { process.close() }
    return try await withTaskCancellationHandler {
      let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
      while process.isRunning {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
          _ = process.terminateAndWait()
          throw ServiceAgentSetupInstallError.commandFailed(
            "安装超时", diagnosticCode: "INSTALL_TIMEOUT")
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      let termination = process.reapIfExited()
      process.drainRemainingOutput()
      guard termination == .exited(0) else {
        throw ServiceAgentSetupInstallError.commandFailed(
          URL(fileURLWithPath: argv[0]).lastPathComponent,
          diagnosticCode: ServiceAgentSetupInstallDiagnostic.code(
            termination: termination, output: output.text))
      }
      return output.text
    } onCancel: {
      _ = process.terminateAndWait()
    }
  }

  private func validate(_ response: URLResponse) throws {
    guard let response = response as? HTTPURLResponse,
      (200..<300).contains(response.statusCode)
    else { throw ServiceAgentSetupInstallError.commandFailed("下载失败，请检查网络或代理") }
  }
}

enum ServiceAgentSetupInstallDiagnostic {
  static func code(termination: ManagedProcessTermination?, output: String) -> String {
    let status: String
    switch termination {
    case .exited(let value): status = "EXIT_\(UInt32(bitPattern: value))"
    case .killed(let value): status = "SIGNAL_\(value)"
    case .notStarted: status = "NOT_STARTED"
    case nil: status = "EXIT_UNKNOWN"
    }
    guard let detail = detail(in: output) else { return status }
    let combined = status + "_" + detail
    return combined.utf8.count <= 64 ? combined : status
  }

  private static func detail(in output: String) -> String? {
    let normalized = output.replacingOccurrences(
      of: #"\x1b\[[0-9;:]*m"#, with: "", options: .regularExpression)
    let pnpmCode = #"ERR_PNPM_[A-Z0-9_]{1,40}"#
    let regex = try! NSRegularExpression(
      pattern: #"(?m)^[\t \u00a0\u2000-\u200a\u202f]*("# + pnpmCode + #"|\["# + pnpmCode
        + #"\])(?=\s|:|$)"#)
    let range = NSRange(normalized.startIndex..., in: normalized)
    if let match = regex.firstMatch(in: normalized, range: range),
      let matchRange = Range(match.range(at: 1), in: normalized)
    {
      let value = normalized[matchRange]
      return value.first == "[" ? String(value.dropFirst().dropLast()) : String(value)
    }
    for code in [
      "ENOENT", "EACCES", "EPERM", "ECONNRESET", "ETIMEDOUT", "ECONNREFUSED",
      "ENOTFOUND", "EAI_AGAIN", "ENETUNREACH", "EHOSTUNREACH",
    ] {
      let pattern = #"\b"# + code + #"\b"#
      if output.range(of: pattern, options: .regularExpression) != nil { return code }
    }
    for (phrase, code) in [
      ("dsh: installation rejected:", "DSH_COMPATIBILITY_REJECTED"),
      ("Open DeepSeek Harness Desktop once to initialize its profile", "DSH_PROFILE_UNINITIALIZED"),
      ("dsh: pnpm was not found", "DSH_PNPM_UNAVAILABLE"),
      ("does not name a package run", "DSH_PACKAGE_RECORD_INVALID"),
      ("started by an earlier package operation", "DSH_PACKAGE_BUSY"),
    ] {
      if output.contains(phrase) { return code }
    }
    return nil
  }
}

private final class ServiceAgentSetupInstallOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes = Data()
  func append(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    if bytes.count < 256 * 1_024 { bytes.append(data.prefix(256 * 1_024 - bytes.count)) }
  }
  var text: String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: bytes, as: UTF8.self)
  }
}

enum ServiceAgentSetupInstallIntegrity {
  static func verify(_ file: URL, digest: String, algorithm: String) throws {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var sha256 = SHA256()
    var sha512 = SHA512()
    while let bytes = try handle.read(upToCount: 1_024 * 1_024), !bytes.isEmpty {
      if algorithm == "sha512" { sha512.update(data: bytes) } else { sha256.update(data: bytes) }
    }
    let actual: String
    if algorithm == "sha512" {
      actual = sha512.finalize().map { String(format: "%02x", $0) }.joined()
    } else {
      actual = sha256.finalize().map { String(format: "%02x", $0) }.joined()
    }
    guard actual == digest.lowercased() else {
      throw ServiceAgentSetupInstallError.checksumMismatch
    }
  }
}

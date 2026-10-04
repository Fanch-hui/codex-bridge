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
  func run(_ argv: [String], cwd: URL, environment: [String: String]) async throws -> String
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

  func run(_ argv: [String], cwd: URL, environment: [String: String]) async throws -> String {
    let output = ServiceAgentSetupInstallOutput()
    let process = try ManagedStdioProcess(
      argv: argv, workingDirectory: cwd.path, environment: environment,
      mergeStandardError: true, onStandardOutput: { output.append($0) })
    process.closeStdin()
    defer { process.close() }
    return try await withTaskCancellationHandler {
      let deadline = ContinuousClock.now.advanced(
        by: .seconds(argv.contains("--version") ? 30 : 900))
      while process.isRunning {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
          _ = process.terminateAndWait()
          throw ServiceAgentSetupInstallError.commandFailed("安装超时")
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      guard process.reapIfExited() == .exited(0) else {
        throw ServiceAgentSetupInstallError.commandFailed(
          URL(fileURLWithPath: argv[0]).lastPathComponent)
      }
      process.drainRemainingOutput()
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

import BridgeSecurity
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct LocalMCPProbe: Sendable {
  static let marker = Data("codex-bridge-local-mcp-probe-v1\n".utf8)
  static let path = "/codex-bridge-local-mcp-probe"
  let endpoint: URL
  let markerPath: String

  init(arguments: [String]) throws {
    guard arguments.count == 4 else { throw ConfigurationError.invalidArguments }
    var options: [String: String] = [:]
    for index in stride(from: 0, to: arguments.count, by: 2) {
      let name = arguments[index]
      guard ["--endpoint", "--marker-file"].contains(name), options[name] == nil else {
        throw ConfigurationError.invalidArguments
      }
      options[name] = arguments[index + 1]
    }
    guard let rawEndpoint = options["--endpoint"], let endpoint = URL(string: rawEndpoint),
      let port = endpoint.port, (1...65535).contains(port),
      rawEndpoint == "http://127.0.0.1:\(port)\(Self.path)",
      let markerPath = options["--marker-file"],
      (markerPath as NSString).isAbsolutePath,
      !markerPath.unicodeScalars.contains(where: { $0.value < 0x20 }),
      URL(fileURLWithPath: markerPath).lastPathComponent == "marker.txt"
    else { throw ConfigurationError.invalidArguments }
    self.endpoint = endpoint
    self.markerPath = markerPath
  }

  func run(sessionConfiguration: URLSessionConfiguration? = nil) async -> Report {
    let file = checkFile()
    let loopback = await checkLoopback(configuration: sessionConfiguration)
    return Report(file: file, loopback: loopback)
  }

  private func checkFile() -> Check {
    do {
      let data = try SecureFileArtifactReader.read(at: markerPath, maximumBytes: Self.marker.count)
      return data == Self.marker ? .passed : .failed("file_marker_mismatch")
    } catch SecureFileArtifactError.fileTooLarge {
      return .failed("file_marker_mismatch")
    } catch {
      return .failed("file_unavailable")
    }
  }

  private func checkLoopback(configuration supplied: URLSessionConfiguration?) async -> Check {
    let configuration = supplied ?? URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 5
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.connectionProxyDictionary = [:]
    let session = URLSession(
      configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    do {
      let (data, response) = try await session.data(from: endpoint)
      guard let response = response as? HTTPURLResponse, response.statusCode == 200,
        response.url == endpoint, data == Self.marker
      else { return .failed("network_response_mismatch") }
      return .passed
    } catch {
      // Keep URLSession's numeric category, never its URL or underlying error text.
      let error = error as NSError
      return .failed(
        error.domain == NSURLErrorDomain ? "network_error_\(error.code)" : "network_unavailable")
    }
  }

  struct Report: Codable, Sendable {
    let file: Check
    let loopback: Check
    var passed: Bool { file.state == "passed" && loopback.state == "passed" }

    func text() throws -> String {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
  }

  struct Check: Codable, Sendable {
    let state: String
    let code: String
    static let passed = Check(state: "passed", code: "ok")
    static func failed(_ code: String) -> Self { Check(state: "failed", code: code) }
  }

  enum ConfigurationError: Error { case invalidArguments }

  private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }
  }
}

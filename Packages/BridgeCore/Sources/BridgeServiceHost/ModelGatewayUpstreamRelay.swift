import BridgeModelGateway
import BridgeProviderRuntime
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum ModelGatewayUpstreamRelay {
  private static let maxChunkBytes = 512 * 1024
  private static let blockedResponseHeaders: Set<String> = [
    "connection", "content-length", "content-encoding", "keep-alive",
    "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade",
  ]

  enum Event: Sendable {
    case head(status: Int, headers: [String: String])
    case chunk(Data)
  }

  struct Reply: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
  }

  static func read(request: URLRequest, maximumBytes: Int) async throws -> Reply {
    try await withEvents(request) { stream in
      var head: (Int, [String: String])?
      var body = Data()
      for try await event in stream {
        try Task.checkCancellation()
        switch event {
        case .head(let status, let headers):
          head = (status, headers)
        case .chunk(let data):
          guard data.count <= maximumBytes - body.count else {
            throw ProviderRuntimeError.remote("upstream_response_too_large")
          }
          body.append(data)
        }
      }
      guard let (status, headers) = head else {
        throw ProviderRuntimeError.remote("invalid_upstream_response")
      }
      return Reply(status: status, headers: headers, body: body)
    }
  }

  static func stream(
    request: URLRequest, into sink: ModelGatewayResponseSink,
    allowedHeaders: Set<String>? = nil, observe: (@Sendable (Data) async -> Void)? = nil
  ) async throws -> Bool {
    try await withEvents(request) { stream in
      var status = 502
      for try await event in stream {
        try Task.checkCancellation()
        switch event {
        case .head(let code, let headers):
          status = code
          let filtered = allowedHeaders.map { names in headers.filter { names.contains($0.key) } }
          try await sink.sendHead(status: code, headers: filtered ?? headers)
        case .chunk(let data):
          var offset = data.startIndex
          while offset < data.endIndex {
            let end = min(offset + maxChunkBytes, data.endIndex)
            try await sink.send(Data(data[offset..<end]))
            offset = end
          }
          if (200...299).contains(status) { await observe?(data) }
        }
      }
      return (200...299).contains(status)
    }
  }

  private static func withEvents<Output: Sendable>(
    _ request: URLRequest,
    consume: (AsyncThrowingStream<Event, any Error>) async throws -> Output
  ) async throws -> Output {
    let (stream, task) = SessionPool.shared.start(request)
    defer { task.cancel() }
    return try await withTaskCancellationHandler {
      try await consume(stream)
    } onCancel: {
      task.cancel()
    }
  }

  /// One long-lived session per deadline keeps upstream TCP/TLS connections warm across turns.
  private final class SessionPool: @unchecked Sendable {
    static let shared = SessionPool()
    private let lock = NSLock()
    private var sessions: [TimeInterval: (URLSession, Router)] = [:]

    func start(_ request: URLRequest) -> (AsyncThrowingStream<Event, any Error>, URLSessionTask) {
      let (session, router) = session(timeout: request.timeoutInterval)
      let task = session.dataTask(with: request)
      let stream = AsyncThrowingStream<Event, any Error> { continuation in
        router.register(task, continuation)
        continuation.onTermination = { _ in task.cancel() }
      }
      task.resume()
      return (stream, task)
    }

    private func session(timeout: TimeInterval) -> (URLSession, Router) {
      lock.lock()
      defer { lock.unlock() }
      if let existing = sessions[timeout] { return existing }
      let configuration = URLSessionConfiguration.ephemeral
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      configuration.urlCache = nil
      configuration.httpCookieStorage = nil
      configuration.urlCredentialStorage = nil
      configuration.httpShouldSetCookies = false
      configuration.timeoutIntervalForRequest = timeout
      configuration.timeoutIntervalForResource = timeout
      let router = Router()
      let created = (
        URLSession(configuration: configuration, delegate: router, delegateQueue: nil), router
      )
      sessions[timeout] = created
      return created
    }
  }

  private final class Router: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [Int: AsyncThrowingStream<Event, any Error>.Continuation] = [:]

    func register(
      _ task: URLSessionTask, _ continuation: AsyncThrowingStream<Event, any Error>.Continuation
    ) {
      lock.lock()
      continuations[task.taskIdentifier] = continuation
      lock.unlock()
    }

    private func continuation(_ task: URLSessionTask, remove: Bool = false)
      -> AsyncThrowingStream<Event, any Error>.Continuation?
    {
      lock.lock()
      defer { lock.unlock() }
      return remove
        ? continuations.removeValue(forKey: task.taskIdentifier)
        : continuations[task.taskIdentifier]
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }

    func urlSession(
      _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
      completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
      guard let http = response as? HTTPURLResponse else {
        continuation(dataTask, remove: true)?.finish(
          throwing: ProviderRuntimeError.remote("invalid_upstream_response"))
        completionHandler(.cancel)
        return
      }
      var headers: [String: String] = [:]
      for (rawKey, rawValue) in http.allHeaderFields {
        let name = String(describing: rawKey).lowercased()
        guard !blockedResponseHeaders.contains(name) else { continue }
        let value = String(describing: rawValue)
        guard !value.contains("\r"), !value.contains("\n") else { continue }
        headers[name] = value
      }
      let code =
        (200...599).contains(http.statusCode) && http.statusCode != 204
          && http.statusCode != 304 ? http.statusCode : 502
      continuation(dataTask)?.yield(.head(status: code, headers: headers))
      completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      guard !data.isEmpty else { return }
      continuation(dataTask)?.yield(.chunk(data))
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
      let continuation = continuation(task, remove: true)
      if let error {
        continuation?.finish(throwing: error)
      } else {
        continuation?.finish()
      }
    }
  }
}

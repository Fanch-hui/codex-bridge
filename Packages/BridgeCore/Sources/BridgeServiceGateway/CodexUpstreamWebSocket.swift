#if os(macOS)
  import BridgeModelGateway
  import Foundation

  /// One upstream Responses WebSocket owned by exactly one client connection.
  final class CodexUpstreamWebSocket: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    struct HandshakeError: Error {
      /// The HTTP status the upstream answered instead of 101, when it answered at all.
      let status: Int?
    }

    private let lock = NSLock()
    private var opening: CheckedContinuation<Void, any Error>?
    private var openResult: Result<Void, any Error>?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    static func connect(_ request: URLRequest, timeout: Duration) async throws
      -> CodexUpstreamWebSocket
    {
      let socket = CodexUpstreamWebSocket()
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await socket.open(request) }
        group.addTask {
          try await Task.sleep(for: timeout)
          throw HandshakeError(status: 504)
        }
        defer { group.cancelAll() }
        do {
          try await group.next()
        } catch {
          socket.close(code: 1001)
          throw error
        }
      }
      return socket
    }

    private func open(_ request: URLRequest) async throws {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      configuration.urlCache = nil
      configuration.httpCookieStorage = nil
      configuration.urlCredentialStorage = nil
      configuration.httpShouldSetCookies = false
      // The handshake deadline is enforced by `connect`; an open socket may idle between turns.
      configuration.timeoutIntervalForRequest = 7 * 24 * 3600
      configuration.timeoutIntervalForResource = 7 * 24 * 3600
      let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
      let task = session.webSocketTask(with: request)
      task.maximumMessageSize = 64 * 1024 * 1024
      lock.withLock {
        self.session = session
        self.task = task
      }
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          let ready = lock.withLock { () -> Result<Void, any Error>? in
            if let openResult { return openResult }
            opening = continuation
            return nil
          }
          if let ready { continuation.resume(with: ready) }
          task.resume()
        }
      } onCancel: {
        task.cancel(with: .goingAway, reason: nil)
      }
    }

    var responseHeaders: [String: String] {
      guard let response = lock.withLock({ task?.response }) as? HTTPURLResponse else { return [:] }
      var headers: [String: String] = [:]
      for (key, value) in response.allHeaderFields {
        headers[String(describing: key).lowercased()] = String(describing: value)
      }
      return headers
    }

    /// The close code the upstream sent, or nil when the socket failed without one.
    var closeCode: Int? {
      guard let code = lock.withLock({ task?.closeCode }), code != .invalid else { return nil }
      return code.rawValue
    }

    func receive() async throws -> ModelGatewayWebSocketMessage {
      guard let task = lock.withLock({ task }) else { throw CancellationError() }
      switch try await task.receive() {
      case .string(let text): return .text(text)
      case .data(let data): return .binary(data)
      @unknown default: throw CancellationError()
      }
    }

    func send(_ message: ModelGatewayWebSocketMessage) async throws {
      guard let task = lock.withLock({ task }) else { throw CancellationError() }
      switch message {
      case .text(let text): try await task.send(.string(text))
      case .binary(let data): try await task.send(.data(data))
      }
    }

    func close(code: Int) {
      let (task, session) = lock.withLock { (self.task, self.session) }
      let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .goingAway
      task?.cancel(with: closeCode, reason: nil)
      session?.finishTasksAndInvalidate()
    }

    private func finishOpening(_ result: Result<Void, any Error>) {
      let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
        guard openResult == nil else { return nil }
        openResult = result
        defer { opening = nil }
        return opening
      }
      continuation?.resume(with: result)
    }

    func urlSession(
      _ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol: String?
    ) {
      finishOpening(.success(()))
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
      let status = (task.response as? HTTPURLResponse)?.statusCode
      finishOpening(.failure(HandshakeError(status: status == 101 ? nil : status)))
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }
  }
#endif

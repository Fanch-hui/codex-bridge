#if os(Windows)
  import BridgeModelGateway
  import BridgeWinHTTP
  import Foundation
  import FoundationNetworking
  import WinSDK

  /// One upstream Responses WebSocket owned by exactly one client connection, on top of
  /// the system WinHTTP WebSocket stack: TLS, certificate validation and proxy
  /// resolution follow OS policy.
  ///
  /// Blocking WinHTTP calls never run on Swift concurrency threads: the handshake and
  /// the frame receive loop each run on dedicated threads, and sends hop onto a serial
  /// queue so at most one `WinHttpWebSocketSend` is in flight per connection.
  final class CodexUpstreamWebSocket: @unchecked Sendable {
    struct HandshakeError: Error {
      /// The HTTP status the upstream answered instead of 101, when it answered at all.
      let status: Int?
    }

    /// A WinHTTP call failed; `code` is the Win32 error it returned.
    struct WinHTTPError: Error {
      let code: DWORD
      var step: String = ""
    }

    /// Lets a raw handle cross into the `DispatchQueue.async` `@Sendable` closure.
    struct SendableHandle: @unchecked Sendable {
      let value: HINTERNET
      init(_ value: HINTERNET) { self.value = value }
    }

    /// At most this many bytes per message, matching the macOS `maximumMessageSize`.
    static let maximumMessageBytes = 64 * 1024 * 1024

    /// Every mutable WinHTTP handle and the receive stream live here so the receive
    /// thread can own this state without retaining the public object: when the caller
    /// drops an accepted socket (e.g. the client vanishes before the local upgrade
    /// completes), `deinit` releases the handles and the thread unwinds.
    final class Core: @unchecked Sendable {
      let lock = NSLock()

      // WinHTTP handles; `socket` is the upgraded WebSocket handle.
      var session: HINTERNET?
      var connection: HINTERNET?
      var request: HINTERNET?
      var socket: HINTERNET?

      var peerCloseCode: Int?
      var closed = false

      /// Sends currently using `socket`. Closing waits for them: once a handle is closed
      /// WinHTTP may hand its value to another connection, so a late send must never
      /// reach `WinHttpWebSocketSend` with it.
      private var activeSends = 0
      private var deferredRelease: (handles: [HINTERNET?], code: Int)?

      typealias MessageStream = AsyncThrowingStream<
        ModelGatewayWebSocketMessage, any Error
      >
      var streamContinuation: MessageStream.Continuation?

      /// Detaches every handle and closes them on a separate thread, so callers on Swift
      /// concurrency threads never wait for the peer's close frame. Returns false when
      /// another closer already released them.
      @discardableResult
      func releaseHandles(code: Int) -> Bool {
        let handles = lock.withLock { () -> [HINTERNET?]? in
          guard !closed else { return nil }
          closed = true
          defer {
            session = nil
            connection = nil
            request = nil
            socket = nil
          }
          let detached = [socket, request, connection, session]
          guard activeSends == 0 else {
            deferredRelease = (detached, code)
            return []
          }
          return detached
        }
        guard let handles else { return false }
        streamContinuation?.finish()
        if !handles.isEmpty { Self.close(handles, code: code) }
        return true
      }

      /// Closes every outstanding handle; safe while a blocking call owns one.
      func closeHandles() {
        releaseHandles(code: 1001)
      }

      /// The socket for one send, or nil once the connection is closing.
      func beginSend() -> HINTERNET? {
        lock.withLock {
          guard !closed, let socket else { return nil }
          activeSends += 1
          return socket
        }
      }

      /// Finishes a send and performs a close that waited for it.
      func endSend() {
        let release = lock.withLock { () -> (handles: [HINTERNET?], code: Int)? in
          activeSends -= 1
          guard activeSends == 0, let release = deferredRelease else { return nil }
          deferredRelease = nil
          return release
        }
        if let release { Self.close(release.handles, code: release.code) }
      }

      /// `WinHttpWebSocketClose` waits for the peer's close frame, so it runs on its own
      /// thread; closing the socket handle also unblocks a pending receive.
      private static func close(_ handles: [HINTERNET?], code: Int) {
        let owned = handles.map { $0.map(SendableHandle.init) }
        Thread.detachNewThread {
          if let socket = owned[0] {
            _ = WinHttpWebSocketClose(socket.value, USHORT(code), nil, 0)
          }
          for handle in owned {
            if let handle { WinHttpCloseHandle(handle.value) }
          }
        }
      }

      /// Accumulates `*_FRAGMENT` chunks into whole messages; `*_MESSAGE` delivers one.
      func receiveLoop() {
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)
        var message = Data()
        while true {
          guard let socket = lock.withLock({ closed ? nil : self.socket }) else { break }
          var read: DWORD = 0
          var bufferType = WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE
          let error = scratch.withUnsafeMutableBytes { buffer in
            WinHttpWebSocketReceive(
              socket, buffer.baseAddress, DWORD(buffer.count), &read, &bufferType)
          }
          if error != NO_ERROR {
            break
          }
          let chunk = scratch[..<Int(read)]
          switch bufferType {
          case WINHTTP_WEB_SOCKET_BINARY_FRAGMENT_BUFFER_TYPE,
            WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE,
            WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE,
            WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE:
            message.append(contentsOf: chunk)
          case WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE:
            finishPeerClose(socket)
            return
          default:
            continue
          }
          if message.count > CodexUpstreamWebSocket.maximumMessageBytes {
            streamContinuation?.finish(throwing: CancellationError())
            releaseHandles(
              code: Int(WINHTTP_WEB_SOCKET_MESSAGE_TOO_BIG_CLOSE_STATUS.rawValue))
            return
          }
          switch bufferType {
          case WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE:
            streamContinuation?.yield(.binary(message))
            message = Data()
          case WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE:
            streamContinuation?.yield(.text(String(decoding: message, as: UTF8.self)))
            message = Data()
          default:
            continue
          }
        }
        streamContinuation?.finish()
        closeHandles()
      }

      /// Reads the peer's close status and finishes the stream normally.
      private func finishPeerClose(_ socket: HINTERNET) {
        var status: USHORT = 0
        var consumed: DWORD = 0
        let error = WinHttpWebSocketQueryCloseStatus(socket, &status, nil, 0, &consumed)
        lock.withLock { peerCloseCode = error == NO_ERROR ? Int(status) : nil }
        streamContinuation?.finish()
        closeHandles()
      }
    }

    let core = Core()

    /// Filled by `performHandshake` in the handshake extension file.
    var responseHeaders: [String: String] = [:]

    /// Serial queue for handshake and sends so they never share a caller's executor thread.
    let operationQueue = DispatchQueue(label: "CodexUpstreamWebSocket.operations")
    var receiveThread: Thread?

    private typealias MessageStream = Core.MessageStream
    private let messageStream: MessageStream
    private var iterator: MessageStream.AsyncIterator?

    init() {
      var continuation: MessageStream.Continuation!
      messageStream = MessageStream { continuation = $0 }
      core.streamContinuation = continuation
    }

    /// Dropping the socket (e.g. an acceptance the client never completed) releases
    /// every WinHTTP handle so the receive thread unwinds.
    deinit {
      core.releaseHandles(code: 1001)
    }

    /// Network or TLS failure carries no status; an HTTP answer carries its code so the
    /// client can reject with it (e.g. 401 to refresh credentials).
    static func connect(_ request: URLRequest, timeout: Duration) async throws
      -> CodexUpstreamWebSocket
    {
      let socket = CodexUpstreamWebSocket()
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await socket.handshake(request) }
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

    /// Runs the blocking handshake off the Swift concurrency pool; `performHandshake`
    /// (in +WinHTTPHandshake.swift) does the WinHTTP sequence and fills the handles.
    func handshake(_ request: URLRequest) async throws {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          operationQueue.async { [self] in
            do {
              try performHandshake(request)
              continuation.resume()
            } catch let error as HandshakeError {
              core.closeHandles()
              continuation.resume(throwing: error)
            } catch {
              core.closeHandles()
              // Network/TLS failures surface as a status-less handshake failure
              // so the caller falls back to 426 instead of seeing WinHTTP errors.
              continuation.resume(throwing: HandshakeError(status: nil))
            }
          }
        }
      } onCancel: { [self] in
        core.closeHandles()
      }
    }

    /// Called once `performHandshake` upgraded the request: spawns the receive thread.
    /// The thread captures `core`, never `self`, so dropping this object lets the
    /// deinit close the handles and unwind the loop.
    func startReceiving() {
      let core = core
      let thread = Thread { core.receiveLoop() }
      receiveThread = thread
      thread.start()
    }

    /// The close code the upstream sent, or nil when the socket failed without one.
    var closeCode: Int? {
      core.lock.withLock { core.peerCloseCode }
    }

    func receive() async throws -> ModelGatewayWebSocketMessage {
      var iterator = core.lock.withLock { () -> MessageStream.AsyncIterator in
        if self.iterator == nil { self.iterator = messageStream.makeAsyncIterator() }
        return self.iterator!
      }
      guard let next = try await iterator.next() else { throw CancellationError() }
      core.lock.withLock { self.iterator = iterator }
      return next
    }

    func send(_ message: ModelGatewayWebSocketMessage) async throws {
      let core = core
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        operationQueue.async {
          guard let socket = core.beginSend() else {
            continuation.resume(throwing: CancellationError())
            return
          }
          defer { core.endSend() }
          let error: DWORD
          switch message {
          case .text(let text):
            var utf8 = Array(text.utf8)
            error = utf8.withUnsafeMutableBytes { buffer in
              WinHttpWebSocketSend(
                socket, WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE,
                buffer.baseAddress, DWORD(buffer.count))
            }
          case .binary(let data):
            var bytes = [UInt8](data)
            error = bytes.withUnsafeMutableBytes { buffer in
              WinHttpWebSocketSend(
                socket, WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE,
                buffer.baseAddress, DWORD(buffer.count))
            }
          }
          continuation.resume(
            with: error == NO_ERROR ? .success(()) : .failure(WinHTTPError(code: error)))
        }
      }
    }

    /// Returns at once; the handles close on a separate thread and the receive thread
    /// unwinds when its pending receive fails.
    func close(code: Int) {
      core.releaseHandles(code: code)
    }
  }
#endif

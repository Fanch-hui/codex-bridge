#if os(Windows)
  import BridgeIPC
  import Foundation
  import WinSDK

  /// Named pipe listener for the Windows background service.
  ///
  /// Wire format per frame: one kind byte (0 request, 1 response, 2 stream
  /// push), a UInt32 little-endian payload length, then the payload. Requests
  /// on one connection are answered strictly in arrival order so the shell can
  /// match responses FIFO; stream pushes are interleaved as kind-2 frames.
  final class BridgeServicePipeListener: ServiceRequestListener, @unchecked Sendable {
    private static let maximumPipeInstances: DWORD = 16
    // PIPE_REJECT_REMOTE_CLIENTS is not exported consistently by WinSDK overlays.
    private static let rejectRemoteClients: DWORD = 0x0000_0008
    private let pipeName: String
    private let composition: ServiceComposition
    private let security: WindowsNamedPipeSecurity
    private let lock = NSLock()
    private let acceptState = PipeAcceptState()
    private var acceptThread: Thread?
    private var running = false
    private var connections: [PipeConnection] = []

    init(pipeName: String, composition: ServiceComposition) throws {
      self.pipeName = pipeName
      self.composition = composition
      self.security = try WindowsNamedPipeSecurity()
    }

    func resume() {
      lock.lock()
      guard !running else {
        lock.unlock()
        return
      }
      running = true
      let thread = Thread { [weak self] in
        self?.acceptLoop()
      }
      thread.name = "codex-bridge.pipe-listener"
      acceptThread = thread
      lock.unlock()
      thread.start()
    }

    func invalidate() {
      lock.lock()
      running = false
      let active = connections
      connections.removeAll()
      _ = acceptState.cancel()
      lock.unlock()
      for connection in active {
        connection.close()
      }
    }

    private func acceptLoop() {
      while isRunning() {
        guard let handle = createPipeInstance() else {
          Thread.sleep(forTimeInterval: 0.1)
          continue
        }
        guard acceptState.begin(handle) else {
          _ = CloseHandle(handle)
          break
        }
        guard let connectEvent = CreateEventW(nil, true, false, nil) else {
          _ = acceptState.finish(handle)
          _ = CloseHandle(handle)
          continue
        }
        var overlapped = OVERLAPPED()
        overlapped.hEvent = connectEvent
        let connected = ConnectNamedPipe(handle, &overlapped)
        var error: DWORD = 0
        if !connected { error = GetLastError() }
        let accepted: Bool
        if connected || error == ERROR_PIPE_CONNECTED {
          accepted = true
        } else if error == ERROR_IO_PENDING {
          accepted = acceptState.waitForConnection(
            handle: handle,
            overlapped: &overlapped,
            connectEvent: connectEvent
          )
        } else {
          accepted = false
        }
        _ = CloseHandle(connectEvent)
        guard acceptState.finish(handle) else {
          _ = CloseHandle(handle)
          break
        }
        guard accepted, isRunning() else {
          _ = CloseHandle(handle)
          if !isRunning() { break }
          continue
        }
        guard LocalAppPeerIdentity.accepts(pipe: handle) else {
          _ = CloseHandle(handle)
          continue
        }
        guard let io = NamedPipeOverlappedIO() else {
          _ = CloseHandle(handle)
          continue
        }
        let writer = PipeFrameWriter(handle: handle, io: io)
        let controller = BridgeServiceRequestController(
          composition: composition,
          streamSink: PipeStreamSink(writer: writer)
        )
        let connection = PipeConnection(
          handle: handle,
          io: io,
          writer: writer,
          controller: controller
        )
        lock.lock()
        guard running else {
          lock.unlock()
          connection.close()
          return
        }
        connections.append(connection)
        lock.unlock()
        connection.start { [weak self] connection in
          self?.remove(connection)
        }
      }
    }

    private func isRunning() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return running
    }

    private func remove(_ connection: PipeConnection) {
      lock.lock()
      connections.removeAll { $0 === connection }
      lock.unlock()
    }

    private func createPipeInstance() -> HANDLE? {
      var attributes = security.attributes
      return pipeName.withCString(encodedAs: UTF16.self) { name in
        let handle = CreateNamedPipeW(
          name,
          DWORD(PIPE_ACCESS_DUPLEX) | DWORD(FILE_FLAG_OVERLAPPED),
          DWORD(PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT) | Self.rejectRemoteClients,
          Self.maximumPipeInstances,
          DWORD(BridgeServiceIPC.maximumMessageBytes),
          DWORD(BridgeServiceIPC.maximumMessageBytes),
          DWORD(0),
          withUnsafeMutablePointer(to: &attributes) { $0 }
        )
        return handle == INVALID_HANDLE_VALUE ? nil : handle
      }
    }
  }

  /// Serializes all frame writes (responses and stream pushes) on one pipe.
  final class PipeFrameWriter: @unchecked Sendable {
    private let handle: HANDLE
    private let io: NamedPipeOverlappedIO
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private var closed = false

    init(handle: HANDLE, io: NamedPipeOverlappedIO) {
      self.handle = handle
      self.io = io
    }

    func write(kind: UInt8, payload: Data) -> Bool {
      var frame = Data([kind])
      var length = UInt32(payload.count).littleEndian
      withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
      frame.append(payload)
      writeLock.lock()
      defer { writeLock.unlock() }
      stateLock.lock()
      let isClosed = closed
      if !isClosed {
        io.beginTransfer()
      }
      stateLock.unlock()
      guard !isClosed else { return false }
      defer { io.endTransfer() }
      do {
        try io.writeFullyWhileTracked(handle, data: frame)
        return true
      } catch {
        return false
      }
    }

    func close() {
      stateLock.lock()
      guard !closed else {
        stateLock.unlock()
        return
      }
      closed = true
      stateLock.unlock()
      io.requestCancellation()
      _ = CancelIoEx(handle, nil)
      io.waitForTransfersDrained()
      _ = CloseHandle(handle)
    }
  }

  /// One connected shell session: serves requests on a dedicated thread.
  private final class PipeConnection: @unchecked Sendable {
    private let handle: HANDLE
    private let io: NamedPipeOverlappedIO
    private let writer: PipeFrameWriter
    private let controller: BridgeServiceRequestController
    private let closeLock = NSLock()
    private var closed = false

    init(
      handle: HANDLE,
      io: NamedPipeOverlappedIO,
      writer: PipeFrameWriter,
      controller: BridgeServiceRequestController
    ) {
      self.handle = handle
      self.io = io
      self.writer = writer
      self.controller = controller
    }

    func start(closeCallback: @escaping @Sendable (PipeConnection) -> Void) {
      let thread = Thread { [weak self] in
        self?.serve(closeCallback: closeCallback)
      }
      thread.name = "codex-bridge.pipe-session"
      thread.stackSize = 1 << 20
      thread.start()
    }

    private func serve(closeCallback: @escaping @Sendable (PipeConnection) -> Void) {
      defer {
        close()
        closeCallback(self)
      }
      while true {
        guard let (kind, payload) = readFrame() else { return }
        guard kind == 0 else {
          // Only requests are accepted from the shell.
          return
        }
        let response = dispatchSync(payload)
        guard writer.write(kind: 1, payload: response) else { return }
        guard shouldRequestShutdown(request: payload, response: response) else { continue }
        ServiceTerminationSignal.request()
        return
      }
    }

    private func shouldRequestShutdown(request: Data, response: Data) -> Bool {
      guard
        let decodedRequest = try? BridgeServiceIPCCodec.decodeRequest(request),
        decodedRequest.operation == .shutdownService,
        let decodedResponse = try? BridgeServiceIPCCodec.response(response)
      else { return false }
      return decodedResponse.error == nil
    }

    /// Bridges the async controller dispatch onto the blocking session thread.
    private func dispatchSync(_ payload: Data) -> Data {
      let semaphore = DispatchSemaphore(value: 0)
      nonisolated(unsafe) var response: Data?
      let controller = controller
      Task {
        response = await controller.dispatch(payload)
        semaphore.signal()
      }
      semaphore.wait()
      return response ?? Data()
    }

    private func readFrame() -> (kind: UInt8, payload: Data)? {
      guard let header = readFully(5) else { return nil }
      let kind = header[header.startIndex]
      let length = header.withUnsafeBytes { raw in
        raw.loadUnaligned(fromByteOffset: 1, as: UInt32.self).littleEndian
      }
      guard length <= BridgeServiceIPC.maximumMessageBytes else { return nil }
      guard let payload = readFully(length) else { return nil }
      return (kind, payload)
    }

    private func readFully(_ count: UInt32) -> Data? {
      closeLock.lock()
      guard !closed else {
        closeLock.unlock()
        return nil
      }
      io.beginTransfer()
      closeLock.unlock()
      defer { io.endTransfer() }
      return io.readFullyWhileTracked(handle, count: count)
    }

    func close() {
      closeLock.lock()
      guard !closed else {
        closeLock.unlock()
        return
      }
      closed = true
      closeLock.unlock()
      controller.stopStreaming()
      writer.close()
    }
  }

  /// Streams controller pushes to the connected shell as kind-2 frames.
  private final class PipeStreamSink: ServiceStreamSink, @unchecked Sendable {
    private let writer: PipeFrameWriter

    init(writer: PipeFrameWriter) {
      self.writer = writer
    }

    func push(_ payload: Data) {
      _ = writer.write(kind: 2, payload: payload)
    }
  }
#endif

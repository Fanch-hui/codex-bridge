#if os(macOS)
  import BridgeIPC
  import Darwin
  import Foundation

  /// A narrowly scoped, authenticated bootstrap for sandboxed local MCP children.
  final class MacLocalMCPListener: ServiceRequestListener, @unchecked Sendable {
    private let descriptor: Int32
    private let path: String
    private let expectedClient: URL
    private let controller: BridgeServiceRequestController
    private let lock = NSLock()
    private var running = false
    private var invalidated = false
    private var connections: [UUID: MacLocalMCPChannel] = [:]

    init(
      composition: ServiceComposition,
      path: String? = nil,
      expectedClient: URL? = nil
    ) throws {
      guard let executable = Bundle.main.executableURL else {
        throw MacLocalMCPError.invalidIdentity
      }
      self.path = try path ?? MacLocalMCPEndpoint.socketPath()
      self.expectedClient =
        try expectedClient
        ?? MacLocalMCPEndpoint.appExecutableURL(from: executable)
      controller = BridgeServiceRequestController(
        composition: composition, maximumConcurrentRequests: 1)
      try MacLocalMCPEndpoint.prepareDirectory(path: self.path)
      descriptor = try MacLocalMCPChannel.createDescriptor()
      do {
        try Self.removeStaleSocket(self.path)
        try MacLocalMCPChannel.withAddress(path: self.path) { address, length in
          guard bind(descriptor, address, length) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
          }
        }
        guard chmod(self.path, 0o600) == 0, listen(descriptor, 4) == 0,
          fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0
        else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      } catch {
        Darwin.close(descriptor)
        throw error
      }
    }

    deinit { invalidate() }

    func resume() {
      let start = lock.withLock {
        guard !running, !invalidated else { return false }
        running = true
        return true
      }
      guard start else { return }
      let thread = Thread { [weak self] in self?.acceptLoop() }
      thread.name = "codex-bridge.local-mcp"
      thread.start()
    }

    func invalidate() {
      let active = lock.withLock { () -> [MacLocalMCPChannel] in
        guard !invalidated else { return [] }
        invalidated = true
        running = false
        Darwin.close(descriptor)
        unlink(path)
        let active = Array(connections.values)
        connections.removeAll()
        return active
      }
      for channel in active { channel.close() }
    }

    private func acceptLoop() {
      while lock.withLock({ running }) {
        var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&event, 1, 200) > 0 else { continue }
        let accepted = lock.withLock { running ? accept(descriptor, nil, nil) : -1 }
        guard accepted >= 0 else { continue }
        guard
          MacLocalMCPChannel.acceptsPeer(
            descriptor: accepted, expectedExecutableURL: expectedClient
          )
        else {
          Darwin.close(accepted)
          continue
        }
        let channel: MacLocalMCPChannel
        do { channel = try MacLocalMCPChannel(descriptor: accepted) } catch {
          Darwin.close(accepted)
          continue
        }
        let id = UUID()
        let attached = lock.withLock {
          guard running, connections.count < 4 else { return false }
          connections[id] = channel
          return true
        }
        guard attached else {
          channel.close()
          continue
        }
        Thread { [weak self, channel] in
          do {
            let request = try channel.readFrame()
            Task { [weak self, channel] in
              guard let self else {
                channel.close()
                return
              }
              defer { self.finish(id, channel: channel) }
              let response = await self.response(to: request)
              // The client may close or time out while the service prepares its endpoint.
              do { try channel.writeFrame(response) } catch { channel.close() }
            }
          } catch {
            self?.finish(id, channel: channel)
            channel.close()
          }
        }.start()
      }
    }

    func response(to data: Data) async -> Data {
      guard let request = try? BridgeServiceIPCCodec.decodeRequest(data),
        request.operation == .getLocalMCPConnection,
        let payload = try? BridgeServiceIPCCodec.payload(IPCMCPClientRequest.self, from: request),
        payload.clientID == "google.gemini"
      else {
        return BridgeServiceRequestController.fallbackFailure(
          requestID: (try? BridgeServiceIPCCodec.decodeRequest(data).requestID) ?? "invalid",
          code: "unsupported_operation",
          message: "This endpoint only provides Gemini local MCP configuration."
        )
      }
      return await controller.dispatch(data)
    }

    private func finish(_ id: UUID, channel: MacLocalMCPChannel) {
      lock.withLock { _ = connections.removeValue(forKey: id) }
      channel.close()
    }

    private static func removeStaleSocket(_ path: String) throws {
      var metadata = stat()
      guard lstat(path, &metadata) == 0 else {
        if errno == ENOENT { return }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      guard metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == S_IFSOCK else {
        throw POSIXError(.EACCES)
      }
      // A private socket with a live listener belongs to an existing service.
      let probe = try MacLocalMCPChannel.createDescriptor()
      defer { Darwin.close(probe) }
      let result = try MacLocalMCPChannel.withAddress(path: path) { address, length in
        Darwin.connect(probe, address, length)
      }
      guard result != 0 else { throw POSIXError(.EADDRINUSE) }
      guard errno == ECONNREFUSED else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      guard unlink(path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
  }
#endif

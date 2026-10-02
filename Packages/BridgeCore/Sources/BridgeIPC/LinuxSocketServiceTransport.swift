#if os(Linux)
  import Foundation

  public final class LinuxSocketServiceTransport: ServiceRequestTransport, @unchecked Sendable {
    private struct Pending {
      let channel: LinuxSocketChannel
      let continuation: CheckedContinuation<Data, any Error>
    }

    private let path: String
    private let lock = NSLock()
    private var channel: LinuxSocketChannel?
    private var pending: [Pending] = []
    private var invalidated = false
    private var handler: (@Sendable (Data) -> Void)?

    public init(path: String = LinuxServiceEndpoint.socketPath) {
      self.path = path
    }

    deinit { invalidate() }

    public var streamHandler: (@Sendable (Data) -> Void)? {
      get { lock.withLock { handler } }
      set { lock.withLock { handler = newValue } }
    }

    public func perform(_ data: Data) async throws -> Data {
      try await withCheckedThrowingContinuation { continuation in
        let active: LinuxSocketChannel
        do {
          active = try connection()
        } catch {
          continuation.resume(throwing: BridgeServiceClientError.unavailable)
          return
        }
        var registered = false
        do {
          try active.writeFrame(kind: 0, payload: data) {
            try lock.withLock {
              guard !invalidated, channel === active else { throw LinuxSocketError.closed }
              pending.append(Pending(channel: active, continuation: continuation))
              registered = true
            }
          }
        } catch {
          if registered {
            retire(active)
          } else {
            continuation.resume(throwing: BridgeServiceClientError.unavailable)
          }
        }
      }
    }

    public func invalidate() {
      let active = lock.withLock {
        invalidated = true
        return channel
      }
      if let active { retire(active) }
    }

    private func connection() throws -> LinuxSocketChannel {
      try lock.withLock {
        guard !invalidated else { throw LinuxSocketError.closed }
        if let channel { return channel }
        let opened = try LinuxSocketChannel.connect(path: path)
        guard
          LinuxSocketIdentity.accepts(
            descriptor: opened.descriptor, executableNames: ["codex-bridge-service"]
          )
        else {
          opened.close()
          throw LinuxSocketError.invalidIdentity
        }
        channel = opened
        let reader = Thread { [weak self, opened] in self?.readLoop(opened) }
        reader.name = "codex-bridge.socket-client"
        reader.start()
        return opened
      }
    }

    private func readLoop(_ active: LinuxSocketChannel) {
      defer { retire(active) }
      while let frame = try? active.readFrame() {
        switch frame.kind {
        case 1:
          let response = lock.withLock { () -> Pending? in
            guard let index = pending.firstIndex(where: { $0.channel === active }) else {
              return nil
            }
            return pending.remove(at: index)
          }
          response?.continuation.resume(returning: frame.payload)
        case 2:
          let callback = lock.withLock { channel === active ? handler : nil }
          callback?(frame.payload)
        default:
          return
        }
      }
    }

    private func retire(_ active: LinuxSocketChannel) {
      let failed = lock.withLock {
        if channel === active { channel = nil }
        let failed = pending.filter { $0.channel === active }
        pending.removeAll { $0.channel === active }
        return failed
      }
      active.close()
      for response in failed {
        response.continuation.resume(throwing: BridgeServiceClientError.unavailable)
      }
    }
  }
#endif

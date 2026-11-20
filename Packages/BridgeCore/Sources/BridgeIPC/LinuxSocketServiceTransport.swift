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
    private var pendingFIFO: [Pending] = []
    private var pendingTagged: [UInt64: Pending] = [:]
    private var nextTag: UInt64 = 1
    private var multiplexingEnabled: Bool
    private var multiplexedConfirmed = false
    private var invalidated = false
    private var handler: (@Sendable (Data) -> Void)?

    public init(path: String = LinuxServiceEndpoint.socketPath, multiplexed: Bool = true) {
      self.path = path
      self.multiplexingEnabled = multiplexed
    }

    deinit { invalidate() }

    public var streamHandler: (@Sendable (Data) -> Void)? {
      get { lock.withLock { handler } }
      set { lock.withLock { handler = newValue } }
    }

    public func perform(_ data: Data) async throws -> Data {
      let useMultiplexed = lock.withLock { multiplexingEnabled }
      do {
        return try await performOnce(data, multiplexed: useMultiplexed)
      } catch BridgeServiceClientError.unavailable
        where useMultiplexed && lock.withLock({ !multiplexingEnabled && !multiplexedConfirmed })
        && ServiceMultiplexedFrame.allowsLegacyFallback(for: data)
      {
        return try await performOnce(data, multiplexed: false)
      }
    }

    private func performOnce(_ data: Data, multiplexed: Bool) async throws -> Data {
      try await withCheckedThrowingContinuation { continuation in
        let active: LinuxSocketChannel
        do {
          active = try connection()
        } catch {
          continuation.resume(throwing: BridgeServiceClientError.unavailable)
          return
        }
        var registered = false
        let frameKind: UInt8
        let wirePayload: Data
        let allocatedTag: UInt64
        if multiplexed {
          allocatedTag = lock.withLock {
            let tag = nextTag
            nextTag &+= 1
            if nextTag == 0 { nextTag = 1 }
            return tag
          }
          frameKind = ServiceFrameKind.multiplexedRequest
          wirePayload = ServiceMultiplexedFrame.encode(tag: allocatedTag, payload: data)
        } else {
          allocatedTag = 0
          frameKind = ServiceFrameKind.legacyRequest
          wirePayload = data
        }
        do {
          try active.writeFrame(kind: frameKind, payload: wirePayload) {
            try lock.withLock {
              guard !invalidated, channel === active else { throw LinuxSocketError.closed }
              let entry = Pending(channel: active, continuation: continuation)
              if multiplexed {
                pendingTagged[allocatedTag] = entry
              } else {
                pendingFIFO.append(entry)
              }
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
        case ServiceFrameKind.legacyResponse:
          let response = lock.withLock { () -> Pending? in
            guard let index = pendingFIFO.firstIndex(where: { $0.channel === active }) else {
              return nil
            }
            return pendingFIFO.remove(at: index)
          }
          response?.continuation.resume(returning: frame.payload)
        case ServiceFrameKind.multiplexedResponse:
          guard let (tag, body) = ServiceMultiplexedFrame.decode(frame.payload) else { return }
          let response = lock.withLock { () -> Pending? in
            multiplexedConfirmed = true
            guard channel === active, let entry = pendingTagged[tag], entry.channel === active
            else { return nil }
            return pendingTagged.removeValue(forKey: tag)
          }
          response?.continuation.resume(returning: body)
        case ServiceFrameKind.streamPush:
          let callback = lock.withLock { channel === active ? handler : nil }
          callback?(frame.payload)
        default:
          return
        }
      }
    }

    private func retire(_ active: LinuxSocketChannel) {
      let failed = lock.withLock { () -> [Pending] in
        if channel === active { channel = nil }
        let failedFIFO = pendingFIFO.filter { $0.channel === active }
        pendingFIFO.removeAll { $0.channel === active }
        var failedTagged: [Pending] = []
        for (tag, entry) in pendingTagged where entry.channel === active {
          failedTagged.append(entry)
          pendingTagged.removeValue(forKey: tag)
        }
        if multiplexingEnabled && !multiplexedConfirmed && !active.receivedAnyFrame
          && !failedTagged.isEmpty
        {
          multiplexingEnabled = false
        }
        return failedFIFO + failedTagged
      }
      active.close()
      for response in failed {
        response.continuation.resume(throwing: BridgeServiceClientError.unavailable)
      }
    }
  }
#endif

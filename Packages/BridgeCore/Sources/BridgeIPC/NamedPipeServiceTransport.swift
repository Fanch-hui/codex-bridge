#if os(Windows)
  import Foundation
  import WinSDK

  /// Named pipe transport for the Windows desktop shell.
  ///
  /// Frame layout on the pipe: one kind byte (0 legacy request, 1 legacy response,
  /// 2 stream push, 3 multiplexed request, 4 multiplexed response), a UInt32
  /// little-endian payload length, then the payload. Multiplexed frames prefix
  /// the payload with an 8-byte little-endian request tag so concurrent requests
  /// (such as long-polls and interactive RPCs) do not head-of-line block each other.
  final class NamedPipeServiceTransport: ServiceRequestTransport, @unchecked Sendable {
    private struct PendingResponse {
      let state: NamedPipeConnectionState
      let continuation: CheckedContinuation<Data, any Error>
    }

    private let pipeName: String
    private let expectedServerImage: [WCHAR]?
    private let lock = NSLock()
    private var currentState: NamedPipeConnectionState?
    private var retiringStates: [NamedPipeConnectionState] = []
    private var pendingFIFO: [PendingResponse] = []
    private var pendingTagged: [UInt64: PendingResponse] = [:]
    private var nextTag: UInt64 = 1
    private var multiplexingEnabled: Bool
    private var multiplexedConfirmed = false
    private var streamHandlerStore: (@Sendable (Data) -> Void)?
    private var invalidated = false

    var streamHandler: (@Sendable (Data) -> Void)? {
      get {
        lock.lock()
        defer { lock.unlock() }
        return streamHandlerStore
      }
      set {
        lock.lock()
        streamHandlerStore = newValue
        lock.unlock()
      }
    }

    init(
      pipeName: String, multiplexed: Bool = true,
      expectedServerImage: [WCHAR]? = WindowsPipeServerIdentity.expectedServiceImage()
    ) {
      self.pipeName = pipeName
      self.expectedServerImage = expectedServerImage
      self.multiplexingEnabled = multiplexed
    }

    deinit {
      invalidate()
    }

    func perform(_ data: Data) async throws -> Data {
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
        let state: NamedPipeConnectionState
        do {
          state = try connectIfNeeded()
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
          try state.writeFrame(kind: frameKind, payload: wirePayload) { [weak self] in
            guard let self else { return false }
            lock.lock()
            defer { lock.unlock() }
            guard !invalidated, currentState === state else { return false }
            let entry = PendingResponse(state: state, continuation: continuation)
            if multiplexed {
              pendingTagged[allocatedTag] = entry
            } else {
              pendingFIFO.append(entry)
            }
            registered = true
            return true
          }
        } catch {
          if registered {
            retire(state, waitForReader: true)
          } else {
            continuation.resume(throwing: BridgeServiceClientError.unavailable)
          }
        }
      }
    }

    func invalidate() {
      lock.lock()
      guard !invalidated else {
        lock.unlock()
        return
      }
      invalidated = true
      let state = currentState
      currentState = nil
      let retiring = retiringStates
      retiringStates.removeAll(keepingCapacity: false)
      let failed = pendingFIFO + Array(pendingTagged.values)
      pendingFIFO.removeAll()
      pendingTagged.removeAll()
      lock.unlock()

      state?.cancelAndClose(waitForReader: true)
      for retiringState in retiring {
        retiringState.cancelAndClose(waitForReader: true)
      }
      for response in failed {
        response.continuation.resume(throwing: BridgeServiceClientError.unavailable)
      }
    }

    private func connectIfNeeded() throws -> NamedPipeConnectionState {
      while true {
        lock.lock()
        guard !invalidated else {
          lock.unlock()
          throw BridgeServiceClientError.unavailable
        }
        if let state = currentState {
          if !state.isClosed {
            lock.unlock()
            return state
          }
          currentState = nil
          lock.unlock()
          retire(state, waitForReader: true)
          continue
        }

        if let retiringState = retiringStates.popLast() {
          lock.unlock()
          retiringState.cancelAndClose(waitForReader: true)
          continue
        }

        let state: NamedPipeConnectionState
        do {
          state = try makeNamedPipeConnectionStateLocked()
        } catch {
          lock.unlock()
          throw error
        }
        currentState = state
        state.start { [weak self, state] in
          guard let self else {
            state.cancelAndClose(waitForReader: false)
            state.io.signalReaderExited()
            return
          }
          self.readLoop(state)
        }
        lock.unlock()
        return state
      }
    }

    private func makeNamedPipeConnectionStateLocked() throws -> NamedPipeConnectionState {
      var opened = openPipe()
      for _ in 0..<50 where opened == INVALID_HANDLE_VALUE {
        guard GetLastError() == ERROR_PIPE_BUSY else { break }
        pipeName.withCString(encodedAs: UTF16.self) { name in
          _ = WaitNamedPipeW(name, 100)
        }
        opened = openPipe()
      }
      guard opened != INVALID_HANDLE_VALUE else {
        throw BridgeServiceClientError.unavailable
      }
      guard WindowsPipeServerIdentity.accepts(pipe: opened, expectedImage: expectedServerImage),
        let io = NamedPipeOverlappedIO()
      else {
        _ = CloseHandle(opened)
        throw BridgeServiceClientError.unavailable
      }
      return NamedPipeConnectionState(handle: opened, io: io)
    }

    private func openPipe() -> HANDLE {
      pipeName.withCString(encodedAs: UTF16.self) { name in
        CreateFileW(
          name,
          DWORD(0x8000_0000) | DWORD(0x4000_0000),
          0,
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_OVERLAPPED),
          nil
        )
      }
    }

    private func readLoop(_ state: NamedPipeConnectionState) {
      defer { state.io.signalReaderExited() }
      while !state.isClosed {
        guard let frame = state.readFrame() else {
          state.cancelAndClose(waitForReader: false)
          retire(state, waitForReader: false)
          return
        }
        deliver(frame, from: state)
      }
    }

    private func deliver(
      _ frame: (kind: UInt8, payload: Data),
      from state: NamedPipeConnectionState
    ) {
      switch frame.kind {
      case ServiceFrameKind.legacyResponse:
        lock.lock()
        let index = pendingFIFO.firstIndex { $0.state === state && currentState === state }
        let response = index.map { pendingFIFO.remove(at: $0) }
        lock.unlock()
        response?.continuation.resume(returning: frame.payload)
      case ServiceFrameKind.multiplexedResponse:
        guard let (tag, body) = ServiceMultiplexedFrame.decode(frame.payload) else {
          state.cancelAndClose(waitForReader: false)
          retire(state, waitForReader: false)
          return
        }
        lock.lock()
        multiplexedConfirmed = true
        let response: PendingResponse?
        if currentState === state, let entry = pendingTagged[tag], entry.state === state {
          response = pendingTagged.removeValue(forKey: tag)
        } else {
          response = nil
        }
        lock.unlock()
        response?.continuation.resume(returning: body)
      case ServiceFrameKind.streamPush:
        let handler: (@Sendable (Data) -> Void)? = lock.withLock {
          guard currentState === state, !invalidated else { return nil }
          return streamHandlerStore
        }
        handler?(frame.payload)
      default:
        state.cancelAndClose(waitForReader: false)
        retire(state, waitForReader: false)
      }
    }

    private func retire(_ state: NamedPipeConnectionState, waitForReader: Bool) {
      lock.lock()
      if currentState === state {
        currentState = nil
      }
      if waitForReader {
        retiringStates.removeAll { $0 === state }
      } else if !retiringStates.contains(where: { $0 === state }) {
        retiringStates.append(state)
      }
      let failedFIFO = pendingFIFO.filter { $0.state === state }
      pendingFIFO.removeAll { $0.state === state }
      var failedTagged: [PendingResponse] = []
      for (tag, entry) in pendingTagged where entry.state === state {
        failedTagged.append(entry)
        pendingTagged.removeValue(forKey: tag)
      }
      if multiplexingEnabled && !multiplexedConfirmed && !state.receivedAnyFrame
        && !failedTagged.isEmpty
      {
        multiplexingEnabled = false
      }
      lock.unlock()

      state.cancelAndClose(waitForReader: waitForReader)
      for response in failedFIFO + failedTagged {
        response.continuation.resume(throwing: BridgeServiceClientError.unavailable)
      }
    }
  }
#endif

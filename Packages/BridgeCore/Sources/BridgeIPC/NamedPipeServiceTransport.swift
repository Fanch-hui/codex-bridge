#if os(Windows)
  import Foundation
  import WinSDK

  /// Named pipe transport for the Windows desktop shell.
  ///
  /// Frame layout on the pipe: one kind byte (0 request, 1 response, 2 stream
  /// push), a UInt32 little-endian payload length, then the payload. Responses
  /// are matched to requests in FIFO order; the server preserves per-connection
  /// response ordering.
  final class NamedPipeServiceTransport: ServiceRequestTransport, @unchecked Sendable {
    private struct PendingResponse {
      let state: NamedPipeConnectionState
      let continuation: CheckedContinuation<Data, any Error>
    }

    private let pipeName: String
    private let lock = NSLock()
    private var currentState: NamedPipeConnectionState?
    private var retiringStates: [NamedPipeConnectionState] = []
    private var pending: [PendingResponse] = []
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

    init(pipeName: String) {
      self.pipeName = pipeName
    }

    deinit {
      invalidate()
    }

    func perform(_ data: Data) async throws -> Data {
      try await withCheckedThrowingContinuation { continuation in
        let state: NamedPipeConnectionState
        do {
          state = try connectIfNeeded()
        } catch {
          continuation.resume(throwing: BridgeServiceClientError.unavailable)
          return
        }

        var registered = false
        do {
          try state.writeFrame(kind: 0, payload: data) { [weak self] in
            guard let self else { return false }
            lock.lock()
            defer { lock.unlock() }
            guard !invalidated, currentState === state else { return false }
            pending.append(PendingResponse(state: state, continuation: continuation))
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
      let failed = pending
      pending.removeAll()
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
      guard let io = NamedPipeOverlappedIO() else {
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
      case 1:
        lock.lock()
        let index = pending.firstIndex { $0.state === state && currentState === state }
        let response = index.map { pending.remove(at: $0) }
        lock.unlock()
        response?.continuation.resume(returning: frame.payload)
      case 2:
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
      let failed = pending.filter { $0.state === state }
      pending.removeAll { $0.state === state }
      lock.unlock()

      state.cancelAndClose(waitForReader: waitForReader)
      for response in failed {
        response.continuation.resume(throwing: BridgeServiceClientError.unavailable)
      }
    }
  }
#endif

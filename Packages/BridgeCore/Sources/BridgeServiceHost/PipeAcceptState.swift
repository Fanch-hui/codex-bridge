#if os(Windows)
  import Foundation
  import WinSDK

  final class PipeAcceptState: @unchecked Sendable {
    private let lock = NSLock()
    private let cancellationEvent: HANDLE
    private var accepting: HANDLE = INVALID_HANDLE_VALUE
    private var cancelled = false

    init() {
      guard let cancellationEvent = CreateEventW(nil, true, false, nil) else {
        fatalError("Unable to create named-pipe accept cancellation event.")
      }
      self.cancellationEvent = cancellationEvent
    }

    deinit {
      _ = CloseHandle(cancellationEvent)
    }

    func begin(_ handle: HANDLE) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard !cancelled, accepting == INVALID_HANDLE_VALUE else { return false }
      accepting = handle
      return true
    }

    func finish(_ handle: HANDLE) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard accepting == handle else { return false }
      accepting = INVALID_HANDLE_VALUE
      return true
    }

    func cancel() -> HANDLE {
      lock.lock()
      cancelled = true
      let handle = accepting
      accepting = INVALID_HANDLE_VALUE
      _ = SetEvent(cancellationEvent)
      lock.unlock()
      return handle
    }

    func waitForConnection(
      handle: HANDLE,
      overlapped: inout OVERLAPPED,
      connectEvent: HANDLE
    ) -> Bool {
      var waitHandles: [HANDLE?] = [connectEvent, cancellationEvent]
      let result = waitHandles.withUnsafeMutableBufferPointer { handles in
        WaitForMultipleObjects(DWORD(handles.count), handles.baseAddress, false, INFINITE)
      }
      guard result == WAIT_OBJECT_0 else {
        _ = CancelIoEx(handle, &overlapped)
        var transferred: DWORD = 0
        _ = GetOverlappedResult(handle, &overlapped, &transferred, true)
        return false
      }
      return true
    }
  }
#endif

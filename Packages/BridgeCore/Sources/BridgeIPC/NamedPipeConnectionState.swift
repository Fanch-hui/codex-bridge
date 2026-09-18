#if os(Windows)
  import Foundation
  import WinSDK

  /// Owns one named-pipe handle and all I/O that can outlive a request call.
  /// A transport creates a fresh state after a disconnect and waits for the
  /// previous reader and overlapped operations to finish before reuse.
  final class NamedPipeConnectionState: @unchecked Sendable {
    let handle: HANDLE
    let io: NamedPipeOverlappedIO

    private let lifecycleLock = NSLock()
    private let writeLock = NSLock()
    private var closed = false
    private var handleClosed = false

    init(handle: HANDLE, io: NamedPipeOverlappedIO) {
      self.handle = handle
      self.io = io
      io.prepareConnection()
    }

    var isClosed: Bool {
      lifecycleLock.lock()
      defer { lifecycleLock.unlock() }
      return closed
    }

    func start(reader: @escaping @Sendable () -> Void) {
      let thread = Thread {
        reader()
      }
      thread.name = "codex-bridge.pipe-reader"
      thread.stackSize = 1 << 20
      thread.start()
    }

    /// Runs registration and writing in the same serialized section. The
    /// lifecycle path never acquires `writeLock`, so cancellation can interrupt
    /// a blocked write and let this section unwind.
    func writeFrame(
      kind: UInt8,
      payload: Data,
      beforeWrite: () -> Bool
    ) throws {
      var frame = Data([kind])
      var length = UInt32(payload.count).littleEndian
      withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
      frame.append(payload)

      writeLock.lock()
      defer { writeLock.unlock() }
      lifecycleLock.lock()
      guard !closed else {
        lifecycleLock.unlock()
        throw BridgeServiceClientError.unavailable
      }
      io.beginTransfer()
      lifecycleLock.unlock()
      defer { io.endTransfer() }
      guard beforeWrite() else {
        throw BridgeServiceClientError.unavailable
      }
      try io.writeFullyWhileTracked(handle, data: frame)
    }

    func readFrame() -> (kind: UInt8, payload: Data)? {
      lifecycleLock.lock()
      guard !closed else {
        lifecycleLock.unlock()
        return nil
      }
      io.beginTransfer()
      lifecycleLock.unlock()
      defer { io.endTransfer() }
      guard let header = readFullyWhileTracked(5) else { return nil }
      let kind = header[header.startIndex]
      let length = header.withUnsafeBytes { raw in
        raw.loadUnaligned(fromByteOffset: 1, as: UInt32.self).littleEndian
      }
      guard length <= BridgeServiceIPC.maximumMessageBytes else { return nil }
      guard let payload = readFullyWhileTracked(length) else { return nil }
      return (kind, payload)
    }

    /// Cancels every overlapped transfer, waits for the transfers themselves,
    /// then waits for the reader when requested. The handle is closed only
    /// after those waits, so a later connection cannot observe a reused handle
    /// while an old I/O operation still references it.
    func cancelAndClose(waitForReader: Bool) {
      lifecycleLock.lock()
      let shouldCancel = !closed
      closed = true
      lifecycleLock.unlock()

      if shouldCancel {
        io.requestCancellation()
        _ = CancelIoEx(handle, nil)
      }
      io.waitForTransfersDrained()
      if waitForReader {
        io.waitForReaderExit()
      }
      closeHandleIfNeeded()
    }

    private func readFullyWhileTracked(_ count: UInt32) -> Data? {
      io.readFullyWhileTracked(handle, count: count)
    }

    private func closeHandleIfNeeded() {
      lifecycleLock.lock()
      guard !handleClosed else {
        lifecycleLock.unlock()
        return
      }
      handleClosed = true
      lifecycleLock.unlock()
      _ = CloseHandle(handle)
    }
  }
#endif

#if os(Windows)
  import Foundation
  import WinSDK
  import XCTest

  @testable import BridgeIPC
  @testable import BridgeServiceHost

  final class WindowsNamedPipeLifecycleTests: XCTestCase {
    func testConcurrentRequestsKeepFIFOResponseAssociation() async throws {
      let requestCount = 64
      let server = try SynchronousNamedPipeServer(
        name: uniquePipeName(),
        expectedFrames: requestCount
      )
      server.start()
      let transport = NamedPipeServiceTransport(pipeName: server.name)
      defer {
        transport.invalidate()
      }

      let responses = try await withThrowingTaskGroup(
        of: (Int, Data).self,
        returning: [(Int, Data)].self
      ) { group in
        for index in 0..<requestCount {
          group.addTask {
            let request = Data("request-\(index)".utf8)
            let response = try await transport.perform(request)
            return (index, response)
          }
        }
        var values: [(Int, Data)] = []
        for try await value in group {
          values.append(value)
        }
        return values
      }

      XCTAssertEqual(responses.count, requestCount)
      for (index, response) in responses {
        XCTAssertEqual(response, Data("request-\(index)".utf8))
      }
      XCTAssertTrue(server.waitForCompletion())
      XCTAssertNil(server.failureDescription)
    }

    func testBlockedOverlappedWriteClosesWithoutWaitingForPeerRead() async throws {
      let fixture = try OverlappedNamedPipeFixture(name: uniquePipeName())
      let io = try XCTUnwrap(NamedPipeOverlappedIO())
      let writer = PipeFrameWriter(handle: fixture.server, io: io)
      let payload = Data(repeating: 0x5A, count: 8 * 1_024 * 1_024)
      let writeTask = Task.detached {
        writer.write(kind: 2, payload: payload)
      }

      try await Task.sleep(for: .milliseconds(100))
      let closed = expectation(description: "Blocked pipe writer closes")
      let closeTask = Task.detached {
        writer.close()
        closed.fulfill()
      }
      await fulfillment(of: [closed], timeout: 2)
      fixture.closeClient()
      await closeTask.value
      _ = await writeTask.value
    }
  }

  private final class SynchronousNamedPipeServer: @unchecked Sendable {
    let name: String
    private let handle: HANDLE
    private let expectedFrames: Int
    private let completion = DispatchSemaphore(value: 0)
    private let failureLock = NSLock()
    private var failure: String?

    var failureDescription: String? {
      failureLock.lock()
      defer { failureLock.unlock() }
      return failure
    }

    init(name: String, expectedFrames: Int) throws {
      self.name = name
      self.expectedFrames = expectedFrames
      let handle = try createNamedPipe(name: name, overlapped: false)
      self.handle = handle
    }

    func start() {
      let thread = Thread { [self] in
        serve()
      }
      thread.name = "codex-bridge.test.pipe-server"
      thread.start()
    }

    func waitForCompletion() -> Bool {
      completion.wait(timeout: .now() + 5) == .success
    }

    private func serve() {
      defer {
        _ = DisconnectNamedPipe(handle)
        _ = CloseHandle(handle)
        completion.signal()
      }
      let connected = ConnectNamedPipe(handle, nil)
      if !connected && GetLastError() != ERROR_PIPE_CONNECTED {
        recordFailure("ConnectNamedPipe failed: \(GetLastError())")
        return
      }
      for _ in 0..<expectedFrames {
        guard let frame = readFrame(handle) else {
          recordFailure("server could not read a complete frame")
          return
        }
        guard writeFrame(frame, to: handle) else {
          recordFailure("server could not write a response frame")
          return
        }
      }
      _ = FlushFileBuffers(handle)
    }

    private func recordFailure(_ message: String) {
      failureLock.lock()
      failure = message
      failureLock.unlock()
    }
  }

  private final class OverlappedNamedPipeFixture: @unchecked Sendable {
    let server: HANDLE
    private let client: HANDLE

    init(name: String) throws {
      let server = try createNamedPipe(
        name: name,
        overlapped: true,
        bufferBytes: 64 * 1_024
      )
      guard let event = CreateEventW(nil, true, false, nil) else {
        _ = CloseHandle(server)
        throw NamedPipeTestError.api("CreateEventW")
      }
      var overlapped = OVERLAPPED()
      overlapped.hEvent = event
      let connected = ConnectNamedPipe(server, &overlapped)
      if !connected {
        let error = GetLastError()
        guard error == ERROR_IO_PENDING else {
          _ = CloseHandle(event)
          _ = CloseHandle(server)
          throw NamedPipeTestError.win32("ConnectNamedPipe", error)
        }
      }
      let client: HANDLE
      do {
        client = try createNamedPipeClient(name: name)
      } catch {
        _ = CloseHandle(event)
        _ = CloseHandle(server)
        throw error
      }
      self.server = server
      self.client = client
      if !connected {
        guard WaitForSingleObject(event, 5_000) == WAIT_OBJECT_0 else {
          _ = CloseHandle(event)
          _ = CloseHandle(client)
          _ = CloseHandle(server)
          throw NamedPipeTestError.api("ConnectNamedPipe timeout")
        }
        var transferred: DWORD = 0
        guard GetOverlappedResult(server, &overlapped, &transferred, false) else {
          let error = GetLastError()
          _ = CloseHandle(event)
          _ = CloseHandle(client)
          _ = CloseHandle(server)
          throw NamedPipeTestError.win32("GetOverlappedResult", error)
        }
      }
      _ = CloseHandle(event)
    }

    func closeClient() {
      _ = CloseHandle(client)
    }
  }

  private enum NamedPipeTestError: Error {
    case api(String)
    case win32(String, DWORD)
  }

  private func uniquePipeName() -> String {
    "\\\\.\\pipe\\codex-bridge-test-\(Foundation.UUID().uuidString)"
  }

  private func createNamedPipe(
    name: String,
    overlapped: Bool,
    bufferBytes: Int = 16 * 1_024 * 1_024
  ) throws -> HANDLE {
    let flags =
      DWORD(PIPE_ACCESS_DUPLEX)
      | (overlapped ? DWORD(FILE_FLAG_OVERLAPPED) : DWORD(0))
    let handle = name.withCString(encodedAs: UTF16.self) { pointer in
      CreateNamedPipeW(
        pointer,
        flags,
        DWORD(PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT),
        1,
        DWORD(bufferBytes),
        DWORD(bufferBytes),
        0,
        nil
      )
    }
    guard let handle, handle != INVALID_HANDLE_VALUE else {
      throw NamedPipeTestError.win32("CreateNamedPipeW", GetLastError())
    }
    return handle
  }

  private func createNamedPipeClient(name: String) throws -> HANDLE {
    let handle = name.withCString(encodedAs: UTF16.self) { pointer in
      CreateFileW(
        pointer,
        DWORD(0x8000_0000) | DWORD(0x4000_0000),
        0,
        nil,
        DWORD(OPEN_EXISTING),
        DWORD(FILE_FLAG_OVERLAPPED),
        nil
      )
    }
    guard let handle, handle != INVALID_HANDLE_VALUE else {
      throw NamedPipeTestError.win32("CreateFileW", GetLastError())
    }
    return handle
  }

  private func readFrame(_ handle: HANDLE) -> Data? {
    guard let header = readBytes(handle, count: 5) else { return nil }
    let length = header.withUnsafeBytes { raw in
      raw.loadUnaligned(fromByteOffset: 1, as: UInt32.self).littleEndian
    }
    guard length <= BridgeServiceIPC.maximumMessageBytes else { return nil }
    return readBytes(handle, count: Int(length))
  }

  private func writeFrame(_ payload: Data, to handle: HANDLE) -> Bool {
    var frame = Data([1])
    var length = UInt32(payload.count).littleEndian
    withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    frame.append(payload)
    return writeBytes(frame, to: handle)
  }

  private func readBytes(_ handle: HANDLE, count: Int) -> Data? {
    guard count > 0 else { return Data() }
    var data = Data(count: count)
    let success = data.withUnsafeMutableBytes { raw -> Bool in
      guard let baseAddress = raw.baseAddress else { return false }
      var offset = 0
      while offset < count {
        var read: DWORD = 0
        guard
          ReadFile(
            handle,
            baseAddress.advanced(by: offset),
            DWORD(count - offset),
            &read,
            nil
          ), read > 0
        else { return false }
        offset += Int(read)
      }
      return true
    }
    return success ? data : nil
  }

  private func writeBytes(_ data: Data, to handle: HANDLE) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
      guard let baseAddress = raw.baseAddress else { return false }
      var offset = 0
      while offset < raw.count {
        var written: DWORD = 0
        guard
          WriteFile(
            handle,
            baseAddress.advanced(by: offset),
            DWORD(raw.count - offset),
            &written,
            nil
          ), written > 0
        else { return false }
        offset += Int(written)
      }
      return true
    }
  }
#endif

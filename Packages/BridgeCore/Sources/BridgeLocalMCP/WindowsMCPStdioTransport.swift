#if os(Windows)
  import Dispatch
  import Foundation
  import Logging
  import MCP
  import WinSDK

  actor WindowsMCPStdioTransport: Transport {
    nonisolated let logger = Logger(
      label: "bridge.local-mcp.stdio", factory: { _ in SwiftLogNoOpLogHandler() }
    )
    private let input: FileHandle
    private let output: FileHandle
    private let writeQueue = DispatchQueue(label: "bridge.local-mcp.output")
    private let messages: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private var connected = false

    init(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
      self.input = input
      self.output = output
      (messages, continuation) = AsyncThrowingStream.makeStream(
        bufferingPolicy: .bufferingOldest(64))
    }

    func connect() {
      guard !connected else { return }
      connected = true
      let input = input
      let continuation = continuation
      DispatchQueue(label: "bridge.local-mcp.input").async {
        Self.read(input: input, continuation: continuation)
      }
    }

    func disconnect() {
      connected = false
      continuation.finish()
    }

    func receive() -> AsyncThrowingStream<Data, any Error> { messages }

    func send(_ data: Data) async throws {
      guard connected else { throw LocalMCPError.closed }
      let output = output
      var line = data
      line.append(10)
      let message = line
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        writeQueue.async {
          do {
            try output.write(contentsOf: message)
            continuation.resume()
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    }

    private nonisolated static func read(
      input: FileHandle, continuation: AsyncThrowingStream<Data, any Error>.Continuation
    ) {
      do {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while let chunk = try readChunk(input: input, buffer: &buffer) {
          pending.append(chunk)
          while let end = pending.firstIndex(of: 10) {
            let line = Data(pending[..<end])
            pending.removeSubrange(...end)
            guard line.count <= 16 * 1024 * 1024 else { throw LocalMCPError.inputOverflow }
            if line.isEmpty { continue }
            switch continuation.yield(line) {
            case .enqueued: break
            case .dropped: throw LocalMCPError.inputOverflow
            case .terminated: return
            @unknown default: throw LocalMCPError.closed
            }
          }
          guard pending.count <= 16 * 1024 * 1024 else { throw LocalMCPError.inputOverflow }
        }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }

    private nonisolated static func readChunk(input: FileHandle, buffer: inout [UInt8]) throws
      -> Data?
    {
      var count: DWORD = 0
      // Foundation's bounded read waits for more data while a Windows pipe's writer stays open.
      let succeeded = buffer.withUnsafeMutableBytes { bytes in
        ReadFile(input._handle, bytes.baseAddress, DWORD(bytes.count), &count, nil)
      }
      if !succeeded {
        if GetLastError() == ERROR_BROKEN_PIPE { return nil }
        throw LocalMCPError.closed
      }
      return count > 0 ? Data(buffer.prefix(Int(count))) : nil
    }
  }
#endif

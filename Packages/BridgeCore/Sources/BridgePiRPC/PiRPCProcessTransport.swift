import BridgeProcess
import Foundation

public struct PiRPCLaunch: Sendable {
  public let argv: [String]
  public let executableArgv: [String]
  public let workingDirectory: String
  public let environment: [String: String]

  public init(
    argv: [String],
    executableArgv: [String]? = nil,
    workingDirectory: String,
    environment: [String: String]
  ) {
    self.argv = argv
    self.executableArgv = executableArgv ?? Array(argv.prefix(1))
    self.workingDirectory = workingDirectory
    self.environment = environment
  }
}

public final class PiRPCProcessTransport: PiRPCTransport, @unchecked Sendable {
  public var incoming: AsyncThrowingStream<Data, any Error> { output.stream }
  private let process: ManagedStdioProcess
  private let output: PiProcessOutput
  private let diagnostics = BoundedProcessOutputCollector(maximumBytes: 64 * 1_024)
  private let lock = NSLock()
  private var monitor: Task<Void, Never>?
  private var closing = false
  private let maximumRecordBytes: Int

  public init(launch: PiRPCLaunch, maximumRecordBytes: Int = 16 * 1_024 * 1_024) throws {
    self.maximumRecordBytes = maximumRecordBytes
    let output = PiProcessOutput(maximumRecordBytes: maximumRecordBytes)
    self.output = output
    let diagnostics = self.diagnostics
    process = try ManagedStdioProcess(
      argv: launch.argv, workingDirectory: launch.workingDirectory,
      environment: launch.environment, mergeStandardError: false,
      onStandardOutput: { output.receive($0) }, onStandardError: { diagnostics.append($0) })
    let process = self.process
    monitor = Task.detached { [weak self] in
      let result = await ManagedProcessRunner(defaultTimeout: .seconds(24 * 60 * 60))
        .monitor(process: process)
      let closing = self?.lock.withLock { self?.closing ?? true } ?? true
      let error: PiRPCError?
      switch result.termination {
      case .exited(let code): error = closing ? nil : .processExited(code)
      default: error = closing ? nil : .processExited(nil)
      }
      output.finish(error: result.timedOut ? PiRPCError.timedOut : error)
    }
  }

  public func send(_ record: Data) async throws {
    guard !record.isEmpty, record.count <= maximumRecordBytes, !record.contains(0x0A) else {
      throw PiRPCError.oversizedFrame
    }
    guard !lock.withLock({ closing }) else { throw PiRPCError.closed }
    var framed = record
    framed.append(0x0A)
    let bytes = framed
    try await Task.detached { [process] in
      try process.writeStdin(bytes, timeout: .seconds(5))
    }.value
  }

  public func close() async {
    let state = lock.withLock { () -> (Bool, Task<Void, Never>?) in
      guard !closing else { return (false, monitor) }
      closing = true
      return (true, monitor)
    }
    guard state.0 else {
      await state.1?.value
      return
    }
    await Task.detached { [process] in process.closeStdin() }.value
    _ = await Task.detached { [process] in process.waitForExit(timeout: .seconds(2)) }.value
    state.1?.cancel()
    await state.1?.value
    output.finish(error: nil)
  }
}

private final class PiProcessOutput: @unchecked Sendable {
  let stream: AsyncThrowingStream<Data, any Error>
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let lock = NSLock()
  private var decoder: BoundedLineDecoder
  private var finished = false

  init(maximumRecordBytes: Int) {
    decoder = BoundedLineDecoder(maximumFrameBytes: maximumRecordBytes)
    let values = AsyncThrowingStream.makeStream(
      of: Data.self, throwing: (any Error).self, bufferingPolicy: .bufferingOldest(64))
    stream = values.stream
    continuation = values.continuation
  }

  func receive(_ data: Data) {
    lock.withLock {
      guard !finished else { return }
      do {
        for frame in try decoder.append(data) {
          if case .dropped = continuation.yield(frame) { throw PiRPCError.oversizedFrame }
        }
      } catch {
        finished = true
        continuation.finish(throwing: error)
      }
    }
  }

  func finish(error: (any Error)?) {
    lock.withLock {
      guard !finished else { return }
      finished = true
      do {
        for frame in try decoder.finish() {
          if case .dropped = continuation.yield(frame) { throw PiRPCError.oversizedFrame }
        }
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
      } catch { continuation.finish(throwing: error) }
    }
  }
}

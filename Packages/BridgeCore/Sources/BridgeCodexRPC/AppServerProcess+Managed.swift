import BridgeProcess
@preconcurrency import Foundation

#if os(Windows)
  import WinSDK
#endif

private actor AppServerStderrBuffer {
  private let limit: Int
  private var data = Data()

  init(limit: Int) {
    self.limit = limit
  }

  func append(_ chunk: Data) {
    guard limit > 0, !chunk.isEmpty else { return }
    if chunk.count >= limit {
      data = Data(chunk.suffix(limit))
      return
    }
    data.append(chunk)
    let overflow = data.count - limit
    if overflow > 0 { data.removeFirst(overflow) }
  }

  func snapshot() -> Data { data }
}

public actor AppServerProcess {
  private let configuration: AppServerConfiguration
  private let stderrBuffer: AppServerStderrBuffer
  private var process: ManagedStdioProcess?
  private var transport: JSONLineTransport?
  private var dispatcher: RPCDispatcher?
  private var stderrTask: Task<Void, Never>?
  private var stderrContinuation: AsyncStream<Data>.Continuation?
  private var terminationTask: Task<Void, Never>?
  private var stopTask: Task<Void, Never>?
  private var hasStarted = false
  private var isClosed = false

  public init(configuration: AppServerConfiguration = .codex()) {
    self.configuration = configuration
    stderrBuffer = AppServerStderrBuffer(limit: configuration.stderrBufferBytes)
  }

  public func start(dispatcher: RPCDispatcher) async throws {
    guard !isClosed else { throw CodexRPCError.notStarted }
    guard !hasStarted else { throw CodexRPCError.alreadyStarted }
    hasStarted = true

    if let reason = configuration.launchFailureReason {
      await dispatcher.terminate(with: .processLaunchFailed(reason))
      throw CodexRPCError.processLaunchFailed(reason)
    }

    let process: ManagedStdioProcess
    do {
      process = try launchProcess()
    } catch {
      await dispatcher.terminate(with: .processLaunchFailed(error.localizedDescription))
      throw CodexRPCError.processLaunchFailed(error.localizedDescription)
    }
    self.process = process
    self.dispatcher = dispatcher

    guard let stderrHandle = process.standardErrorFileHandle else {
      let stopped = await Self.stopTree(process)
      process.close()
      if stopped { self.process = nil }
      let reason = "Codex app-server did not provide a standard error pipe."
      await dispatcher.terminate(with: .processLaunchFailed(reason))
      throw CodexRPCError.processLaunchFailed(reason)
    }
    let transport = JSONLineTransport(
      input: process.standardInputFileHandle,
      output: process.standardOutputFileHandle,
      dispatcher: dispatcher,
      maximumLineBytes: configuration.maximumProtocolLineBytes
    )
    self.transport = transport

    do {
      try await transport.start {
        process.terminateGroup()
      }
      guard !isClosed else { throw CodexRPCError.notStarted }
      let stderrReader = makeStderrReader(handle: stderrHandle, buffer: stderrBuffer)
      stderrTask = stderrReader.task
      stderrContinuation = stderrReader.continuation
      terminationTask = Self.monitor(
        process: process,
        dispatcher: dispatcher
      )
    } catch {
      stderrHandle.readabilityHandler = nil
      await transport.stop()
      let stopped = await Self.stopTree(process)
      process.close()
      if stopped { self.process = nil }
      await dispatcher.terminate(with: .processLaunchFailed(error.localizedDescription))
      throw CodexRPCError.processLaunchFailed(error.localizedDescription)
    }

  }

  public func send(_ value: JSONValue) async throws {
    guard let process, process.isRunning, let transport else {
      throw CodexRPCError.notStarted
    }
    try await transport.write(value)
  }

  public func stop() async {
    isClosed = true
    if let stopTask {
      await stopTask.value
      return
    }
    guard let process else { return }
    let task = Task { await self.performStop(process) }
    stopTask = task
    await task.value
    stopTask = nil
  }

  public func confirmedStopped() async -> Bool {
    if let stopTask { await stopTask.value }
    guard let process else { return true }
    return process.isProcessTreeStopped()
  }

  private func performStop(_ process: ManagedStdioProcess) async {
    let stopped = await Self.stopTree(process)
    await transport?.stop()
    process.standardErrorFileHandle?.readabilityHandler = nil
    terminationTask?.cancel()
    if let terminationTask { await terminationTask.value }
    if let status = process.reapIfExited(gracePeriod: .zero) {
      await dispatcher?.terminate(with: .processExited(Self.exitStatus(status)))
    }
    stderrContinuation?.finish()
    stderrContinuation = nil
    stderrTask?.cancel()
    stderrTask = nil
    process.close()
    transport = nil
    dispatcher = nil
    terminationTask = nil
    if stopped { self.process = nil }
  }

  public func stderrSnapshot() async -> Data {
    await stderrBuffer.snapshot()
  }

  private func launchProcess() throws -> ManagedStdioProcess {
    let environment = configuration.environment ?? ProcessInfo.processInfo.environment
    #if os(Windows)
      do {
        return try launchProcess(at: configuration.executableURL, environment: environment)
      } catch ManagedProcessError.processLaunchFailed(let code)
        where code == Int32(ERROR_ACCESS_DENIED)
      {
        guard
          let copy = try CodexWindowsPackagedRuntime.executableCopyIfPackaged(
            at: configuration.executableURL, environment: environment)
        else { throw ManagedProcessError.processLaunchFailed(code) }
        return try launchProcess(at: copy, environment: environment)
      }
    #else
      return try launchProcess(at: configuration.executableURL, environment: environment)
    #endif
  }

  private func launchProcess(
    at executableURL: URL, environment: [String: String]
  ) throws -> ManagedStdioProcess {
    try ManagedStdioProcess(
      argv: [executableURL.path] + configuration.arguments,
      workingDirectory: configuration.currentDirectoryURL?.path,
      environment: environment,
      mergeStandardError: false,
      onStandardOutput: { _ in },
      readOutput: false
    )
  }

  private static func monitor(
    process: ManagedStdioProcess,
    dispatcher: RPCDispatcher
  ) -> Task<Void, Never> {
    Task.detached(priority: .utility) {
      while process.isRunning {
        if Task.isCancelled { return }
        try? await Task.sleep(for: .milliseconds(25))
      }
      guard !Task.isCancelled else { return }
      let termination = process.reapIfExited(gracePeriod: .zero) ?? .notStarted
      await dispatcher.terminate(with: .processExited(Self.exitStatus(termination)))
    }
  }

  private static func stopTree(_ process: ManagedStdioProcess) async -> Bool {
    await Task.detached(priority: .utility) {
      process.terminateProcessTreeAndWait()
    }.value
  }

  private static func exitStatus(_ termination: ManagedProcessTermination) -> Int32 {
    switch termination {
    case .exited(let status): status
    case .killed(let signal): signal
    case .notStarted: -1
    }
  }

  private func makeStderrReader(
    handle: FileHandle,
    buffer: AppServerStderrBuffer
  ) -> (task: Task<Void, Never>, continuation: AsyncStream<Data>.Continuation) {
    let pair = AsyncStream.makeStream(
      of: Data.self,
      bufferingPolicy: .bufferingNewest(8)
    )
    handle.readabilityHandler = { readableHandle in
      let data = readableHandle.availableData
      if data.isEmpty {
        pair.continuation.finish()
      } else {
        pair.continuation.yield(data)
      }
    }
    let task = Task.detached(priority: .utility) {
      for await data in pair.stream {
        await buffer.append(data)
      }
    }
    return (task, pair.continuation)
  }
}

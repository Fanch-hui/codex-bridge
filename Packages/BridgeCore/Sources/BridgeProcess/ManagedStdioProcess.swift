import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif os(Windows)
  import WinSDK
  import ucrt
#endif

public final class ManagedStdioProcess: @unchecked Sendable {
  public typealias OutputHandler = @Sendable (Data) -> Void

  public let pid: Int32
  private let standardOutputHandle: FileHandle
  private let standardErrorHandle: FileHandle?
  private let standardInputHandle: FileHandle
  private let standardOutputSink: OutputHandler
  private let standardErrorSink: OutputHandler
  private let ownershipRecord: ManagedProcessOwnershipRecord?
  private let lock = NSLock()
  private let inputLock = NSLock()
  private let outputLock = NSLock()
  private var terminationStorage: ManagedProcessTermination?
  private var identityStorage: ManagedProcessIdentity?
  private var inputClosed = false
  private var handlesClosed = false
  #if os(Windows)
    private var windowsProcessHandle: HANDLE?
    private var windowsProcessJob: ManagedWindowsProcessJob?
  #else
    private let posixProcessGroup: ManagedPOSIXProcessGroup
  #endif

  public var identity: ManagedProcessIdentity? {
    lock.lock()
    defer { lock.unlock() }
    return identityStorage
  }

  deinit {
    #if os(Windows)
      if let handle = windowsProcessHandle { _ = CloseHandle(handle) }
    #endif
  }

  public init(
    argv: [String],
    workingDirectory: String?,
    environment: [String: String],
    mergeStandardError: Bool,
    processGroupName: String? = nil,
    onStandardOutput: @escaping OutputHandler,
    onStandardError: @escaping OutputHandler = { _ in },
    readOutput: Bool = true
  ) throws {
    guard let executable = argv.first, !executable.isEmpty, argv.count <= 128,
      argv.allSatisfy({ !$0.contains("\0") }),
      environment.allSatisfy({ !$0.key.contains("\0") && !$0.value.contains("\0") }),
      workingDirectory.map({ !$0.isEmpty && !$0.contains("\0") }) ?? true
    else { throw ManagedProcessError.invalidArgument }
    #if !os(Windows)
      guard executable.hasPrefix("/") else { throw ManagedProcessError.invalidArgument }
    #endif
    guard ManagedProcessOwnership.current == nil || processGroupName == nil else {
      throw ManagedProcessError.invalidArgument
    }
    let ownership = try ManagedProcessOwnership.current?.prepareLaunch()
    ownershipRecord = ownership
    var processCreated = false
    defer {
      if !processCreated { ownership?.remove() }
    }

    #if os(Windows)
      standardOutputSink = onStandardOutput
      standardErrorSink = onStandardError

      let inputPipe = Pipe()
      let outputPipe = Pipe()
      let errorPipe = mergeStandardError ? nil : Pipe()
      let launched: (pid: Int32, handle: HANDLE, job: ManagedWindowsProcessJob)
      do {
        launched = try Self.spawnWindows(
          argv: argv,
          workingDirectory: workingDirectory,
          environment: environment,
          processGroupName: ownership?.groupName ?? processGroupName,
          standardInput: inputPipe,
          standardOutput: outputPipe,
          standardError: errorPipe
        )
      } catch {
        inputPipe.fileHandleForReading.closeFile()
        inputPipe.fileHandleForWriting.closeFile()
        outputPipe.fileHandleForReading.closeFile()
        outputPipe.fileHandleForWriting.closeFile()
        errorPipe?.fileHandleForReading.closeFile()
        errorPipe?.fileHandleForWriting.closeFile()
        throw error
      }
      processCreated = true

      if let ownership {
        do {
          guard let identity = Self.identity(of: launched.pid) else {
            throw ManagedProcessError.processLaunchFailed(-1)
          }
          try ownership.save(identity: identity)
        } catch {
          _ = launched.job.terminate()
          _ = CloseHandle(launched.handle)
          inputPipe.fileHandleForReading.closeFile()
          inputPipe.fileHandleForWriting.closeFile()
          outputPipe.fileHandleForReading.closeFile()
          outputPipe.fileHandleForWriting.closeFile()
          errorPipe?.fileHandleForReading.closeFile()
          errorPipe?.fileHandleForWriting.closeFile()
          throw error
        }
      }

      inputPipe.fileHandleForReading.closeFile()
      outputPipe.fileHandleForWriting.closeFile()
      errorPipe?.fileHandleForWriting.closeFile()

      pid = launched.pid
      standardInputHandle = inputPipe.fileHandleForWriting
      standardOutputHandle = outputPipe.fileHandleForReading
      standardErrorHandle = errorPipe?.fileHandleForReading
      windowsProcessHandle = launched.handle
      windowsProcessJob = launched.job
      identityStorage = Self.identity(of: pid)
    #else
      standardOutputSink = onStandardOutput
      standardErrorSink = onStandardError

      let inputPipe = Pipe()
      let outputPipe = Pipe()
      let errorPipe = mergeStandardError ? nil : Pipe()
      let launchGate = ownership == nil ? nil : Pipe()
      let processID: pid_t
      do {
        #if os(Linux)
          let handles =
            [
              inputPipe.fileHandleForReading, inputPipe.fileHandleForWriting,
              outputPipe.fileHandleForReading, outputPipe.fileHandleForWriting,
            ]
            + (errorPipe.map { [$0.fileHandleForReading, $0.fileHandleForWriting] } ?? [])
            + (launchGate.map { [$0.fileHandleForReading, $0.fileHandleForWriting] } ?? [])
          for handle in handles {
            guard fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
              throw ManagedProcessError.processLaunchFailed(errno)
            }
          }
        #endif
        processID = try Self.spawn(
          argv: ownership == nil ? argv : Self.gatedArguments(argv),
          workingDirectory: workingDirectory,
          environment: environment,
          standardInput: inputPipe.fileHandleForReading.fileDescriptor,
          standardOutput: outputPipe.fileHandleForWriting.fileDescriptor,
          standardError: mergeStandardError
            ? outputPipe.fileHandleForWriting.fileDescriptor
            : errorPipe!.fileHandleForWriting.fileDescriptor,
          launchGate: launchGate?.fileHandleForReading.fileDescriptor
        )
      } catch {
        inputPipe.fileHandleForReading.closeFile()
        inputPipe.fileHandleForWriting.closeFile()
        outputPipe.fileHandleForReading.closeFile()
        outputPipe.fileHandleForWriting.closeFile()
        errorPipe?.fileHandleForReading.closeFile()
        errorPipe?.fileHandleForWriting.closeFile()
        launchGate?.fileHandleForReading.closeFile()
        launchGate?.fileHandleForWriting.closeFile()
        throw error
      }
      processCreated = true

      if let ownership, let launchGate {
        launchGate.fileHandleForReading.closeFile()
        do {
          guard let identity = Self.identity(of: processID) else {
            throw ManagedProcessError.processLaunchFailed(-1)
          }
          try ownership.save(identity: identity)
          try launchGate.fileHandleForWriting.write(contentsOf: Data("run\n".utf8))
          launchGate.fileHandleForWriting.closeFile()
        } catch {
          launchGate.fileHandleForWriting.closeFile()
          _ = kill(-processID, SIGKILL)
          inputPipe.fileHandleForReading.closeFile()
          inputPipe.fileHandleForWriting.closeFile()
          outputPipe.fileHandleForReading.closeFile()
          outputPipe.fileHandleForWriting.closeFile()
          errorPipe?.fileHandleForReading.closeFile()
          errorPipe?.fileHandleForWriting.closeFile()
          throw error
        }
      }

      inputPipe.fileHandleForReading.closeFile()
      outputPipe.fileHandleForWriting.closeFile()
      errorPipe?.fileHandleForWriting.closeFile()

      pid = processID
      standardInputHandle = inputPipe.fileHandleForWriting
      standardOutputHandle = outputPipe.fileHandleForReading
      standardErrorHandle = errorPipe?.fileHandleForReading
      identityStorage = Self.identity(of: processID)
      posixProcessGroup = ManagedPOSIXProcessGroup(pid: processID, identity: identityStorage)
    #endif

    if readOutput {
      standardOutputHandle.readabilityHandler = { [weak self] handle in
        guard let self else { return }
        consumeAvailableData(handle, sink: standardOutputSink)
      }
      standardErrorHandle?.readabilityHandler = { [weak self] handle in
        guard let self else { return }
        consumeAvailableData(handle, sink: standardErrorSink)
      }
    }
  }

  /// Returns the parent-side standard input handle for a caller that owns a
  /// separate transport reader.
  public var standardInputFileHandle: FileHandle { standardInputHandle }

  /// Returns the parent-side standard output handle for a caller that owns a
  /// separate transport reader.
  public var standardOutputFileHandle: FileHandle { standardOutputHandle }

  /// Returns the parent-side standard error handle when stderr is not merged.
  public var standardErrorFileHandle: FileHandle? { standardErrorHandle }

  public func writeStdin(_ data: Data) throws {
    inputLock.lock()
    defer { inputLock.unlock() }
    guard !inputClosed else { throw ManagedProcessError.stdinUnavailable }
    do {
      try standardInputHandle.write(contentsOf: data)
    } catch {
      throw ManagedProcessError.stdinUnavailable
    }
  }

  public func writeStdin(_ data: Data, timeout: Duration) throws {
    inputLock.lock()
    defer { inputLock.unlock() }
    guard !inputClosed else { throw ManagedProcessError.stdinUnavailable }
    #if os(Windows)
      // Anonymous pipe writes block until the child consumes the bytes; run
      // the write on a background queue and bound the wait with the timeout.
      let semaphore = DispatchSemaphore(value: 0)
      nonisolated(unsafe) var writeFailed = false
      let handle = standardInputHandle
      DispatchQueue.global().async {
        do {
          try handle.write(contentsOf: data)
        } catch {
          writeFailed = true
        }
        semaphore.signal()
      }
      let deadline = ContinuousClock.now.advanced(by: timeout)
      while semaphore.wait(timeout: .now() + .milliseconds(20)) == .timedOut {
        if ContinuousClock.now >= deadline {
          throw ManagedProcessError.stdinUnavailable
        }
      }
      if writeFailed { throw ManagedProcessError.stdinUnavailable }
    #else
      let descriptor = standardInputHandle.fileDescriptor
      let previousFlags = fcntl(descriptor, F_GETFL)
      guard previousFlags >= 0,
        fcntl(descriptor, F_SETFL, previousFlags | O_NONBLOCK) == 0
      else {
        throw ManagedProcessError.stdinUnavailable
      }
      defer { _ = fcntl(descriptor, F_SETFL, previousFlags) }

      let deadline = ContinuousClock.now.advanced(by: timeout)
      do {
        try data.withUnsafeBytes { buffer in
          guard let baseAddress = buffer.baseAddress else { return }
          var offset = 0
          while offset < buffer.count {
            let written = systemWrite(
              descriptor,
              baseAddress.advanced(by: offset),
              buffer.count - offset
            )
            if written > 0 {
              offset += written
              continue
            }
            if written == -1, errno == EINTR { continue }
            guard written == -1, errno == EAGAIN || errno == EWOULDBLOCK,
              ContinuousClock.now < deadline
            else {
              throw ManagedProcessError.stdinUnavailable
            }
            Thread.sleep(forTimeInterval: 0.01)
          }
        }
      } catch {
        throw ManagedProcessError.stdinUnavailable
      }
    #endif
  }

  public func closeStdin() {
    inputLock.lock()
    defer { inputLock.unlock() }
    guard !inputClosed else { return }
    inputClosed = true
    standardInputHandle.closeFile()
  }

  public func terminateGroup() {
    #if os(Windows)
      if isRunning { terminateWindowsProcess() }
    #else
      posixProcessGroup.signal(SIGTERM)
    #endif
  }

  public func interruptGroup() {
    #if os(Windows)
      // Windows cannot deliver SIGINT without a shared console; force termination.
      if isRunning { terminateWindowsProcess() }
    #else
      posixProcessGroup.signal(SIGINT)
    #endif
  }

  public func killGroup() {
    #if os(Windows)
      if isRunning { terminateWindowsProcess() }
    #else
      posixProcessGroup.signal(SIGKILL)
    #endif
  }

  public var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    _ = reapIfExitedLocked()
    return terminationStorage == nil
  }

  public func reapIfExited(gracePeriod: Duration = .milliseconds(200))
    -> ManagedProcessTermination?
  {
    lock.lock()
    if let termination = reapIfExitedLocked() {
      lock.unlock()
      return termination
    }
    lock.unlock()

    let deadline = ContinuousClock.now.advanced(by: gracePeriod)
    while ContinuousClock.now < deadline {
      lock.lock()
      let termination = reapIfExitedLocked()
      lock.unlock()
      if let termination { return termination }
      Thread.sleep(forTimeInterval: 0.01)
    }
    return nil
  }

  public func waitForExit(timeout: Duration) -> ManagedProcessTermination? {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if let termination = reapIfExited() { return termination }
      Thread.sleep(forTimeInterval: 0.02)
    }
    return reapIfExited()
  }

  public func terminateAndWait(
    gracePeriod: Duration = .seconds(1),
    killWait: Duration = .seconds(5)
  ) -> ManagedProcessTermination? {
    terminateGroup()
    #if os(Windows)
      if let termination = waitForExit(timeout: gracePeriod) { return termination }
    #else
      if let termination = waitForGroupExit(timeout: gracePeriod) { return termination }
    #endif
    killGroup()
    #if os(Windows)
      return waitForExit(timeout: killWait)
    #else
      return waitForGroupExit(timeout: killWait)
    #endif
  }

  /// Confirms that both the launched process and its managed descendants have exited.
  public func isProcessTreeStopped() -> Bool {
    #if os(Windows)
      lock.lock()
      let job = windowsProcessJob
      lock.unlock()
      return job?.isEmpty() ?? false
    #else
      guard reapIfExited(gracePeriod: .zero) != nil else { return false }
      return !posixProcessGroup.exists
    #endif
  }

  /// Requests termination and returns true only after the managed process tree is gone.
  public func terminateProcessTreeAndWait(
    gracePeriod: Duration = .seconds(1),
    killWait: Duration = .seconds(5)
  ) -> Bool {
    if isProcessTreeStopped() { return true }
    #if os(Windows)
      lock.lock()
      let job = windowsProcessJob
      lock.unlock()
      guard let job else { return false }
      _ = job.terminate()
      let deadline = ContinuousClock.now.advanced(by: gracePeriod + killWait)
      repeat {
        if job.isEmpty() {
          _ = reapIfExited(gracePeriod: .zero)
          return true
        }
        Thread.sleep(forTimeInterval: 0.01)
      } while ContinuousClock.now < deadline
      return false
    #else
      guard terminateAndWait(gracePeriod: gracePeriod, killWait: killWait) != nil else {
        return false
      }
      return isProcessTreeStopped()
    #endif
  }

  #if !os(Windows)
    private func waitForGroupExit(timeout: Duration) -> ManagedProcessTermination? {
      let deadline = ContinuousClock.now.advanced(by: timeout)
      repeat {
        let termination = reapIfExited(gracePeriod: .zero)
        if !posixProcessGroup.exists, let termination { return termination }
        Thread.sleep(forTimeInterval: 0.01)
      } while ContinuousClock.now < deadline
      return nil
    }
  #endif

  public func drainRemainingOutput(timeout: Duration = .seconds(1)) {
    lock.lock()
    let hasTerminated = terminationStorage != nil
    lock.unlock()
    guard hasTerminated else { return }

    outputLock.lock()
    guard !handlesClosed else {
      outputLock.unlock()
      return
    }
    standardOutputHandle.readabilityHandler = nil
    standardErrorHandle?.readabilityHandler = nil
    outputLock.unlock()

    let deadline = ContinuousClock.now.advanced(by: timeout)
    drain(standardOutputHandle, sink: standardOutputSink, until: deadline)
    if let standardErrorHandle {
      drain(standardErrorHandle, sink: standardErrorSink, until: deadline)
    }
  }

  public func close() {
    outputLock.lock()
    guard !handlesClosed else {
      outputLock.unlock()
      closeStdin()
      if isProcessTreeStopped() { ownershipRecord?.remove() }
      return
    }
    handlesClosed = true
    standardOutputHandle.readabilityHandler = nil
    standardErrorHandle?.readabilityHandler = nil
    standardOutputHandle.closeFile()
    standardErrorHandle?.closeFile()
    outputLock.unlock()
    closeStdin()
    #if os(Windows)
      lock.lock()
      _ = reapIfExitedLocked()
      if terminationStorage != nil, let handle = windowsProcessHandle {
        _ = CloseHandle(handle)
        windowsProcessHandle = nil
        // Keep the job handle until deinitialization so callers can confirm all
        // descendants have exited after requesting termination.
        _ = windowsProcessJob?.terminate()
      }
      lock.unlock()
    #endif
    if isProcessTreeStopped() { ownershipRecord?.remove() }
  }

  #if !os(Windows)
    private static func gatedArguments(_ argv: [String]) -> [String] {
      [
        "/bin/sh", "-c",
        "IFS= read -r bridge_launch <&3 && [ \"$bridge_launch\" = run ] || exit 1; exec 3<&-; exec \"$@\"",
        "bridge-launch",
      ] + argv
    }
  #endif

  private func consumeAvailableData(_ handle: FileHandle, sink: OutputHandler) {
    outputLock.lock()
    defer { outputLock.unlock() }
    guard !handlesClosed else { return }
    let data = handle.availableData
    if !data.isEmpty { sink(data) }
  }

  private func drain(
    _ handle: FileHandle,
    sink: OutputHandler,
    until deadline: ContinuousClock.Instant
  ) {
    while ContinuousClock.now < deadline {
      guard let data = readAvailableData(handle, until: deadline) else { return }
      if data.isEmpty { return }
      sink(data)
    }
  }

  private func readAvailableData(
    _ handle: FileHandle,
    until deadline: ContinuousClock.Instant
  ) -> Data? {
    #if canImport(Darwin) || canImport(Glibc)
      let descriptor = handle.fileDescriptor
      let previousFlags = fcntl(descriptor, F_GETFL)
      guard previousFlags >= 0, fcntl(descriptor, F_SETFL, previousFlags | O_NONBLOCK) == 0
      else { return Data() }
      defer { _ = fcntl(descriptor, F_SETFL, previousFlags) }
      var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
      while ContinuousClock.now < deadline {
        let count = buffer.withUnsafeMutableBytes { bytes in
          systemRead(descriptor, bytes.baseAddress, bytes.count)
        }
        if count > 0 { return Data(buffer.prefix(count)) }
        if count == 0 { return Data() }
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK { return Data() }
        return Data()
      }
      return nil
    #else
      let result = BlockingReadResult()
      nonisolated(unsafe) let unsafeHandle = handle
      DispatchQueue.global(qos: .utility).async {
        result.set(unsafeHandle.availableData)
      }
      let remaining = max(1, Self.milliseconds(until: deadline))
      guard result.wait(milliseconds: remaining) else { return nil }
      return result.value
    #endif
  }

  private static func milliseconds(until deadline: ContinuousClock.Instant) -> Int {
    let remaining = ContinuousClock.now.duration(to: deadline).components
    let seconds = max(0, remaining.seconds)
    let milliseconds = seconds.multipliedReportingOverflow(by: 1_000).partialValue
    let nanos = max(0, remaining.attoseconds / 1_000_000_000_000_000)
    return Int(min(Int64.max, milliseconds + nanos))
  }

  private func reapIfExitedLocked() -> ManagedProcessTermination? {
    if let terminationStorage { return terminationStorage }
    #if os(Windows)
      guard let handle = windowsProcessHandle else { return nil }
      guard WaitForSingleObject(handle, 0) == WAIT_OBJECT_0 else { return nil }
      var exitCode: DWORD = 0
      guard GetExitCodeProcess(handle, &exitCode) else { return nil }
      let termination = ManagedProcessTermination.exited(Int32(bitPattern: exitCode))
      terminationStorage = termination
      return termination
    #else
      var status: Int32 = 0
      let result = systemWaitPID(pid, &status, WNOHANG)
      guard result == pid else { return nil }
      let signal = status & 0x7F
      let termination: ManagedProcessTermination =
        signal == 0 ? .exited((status >> 8) & 0xFF) : .killed(signal)
      terminationStorage = termination
      return termination
    #endif
  }
}

#if os(Windows)
  extension ManagedStdioProcess {
    fileprivate func terminateWindowsProcess() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return windowsProcessJob?.terminate() ?? false
    }
  }
#endif
#if canImport(Darwin)
  private let systemWaitPID = Darwin.waitpid
  private let systemWrite = Darwin.write
  private let systemRead = Darwin.read
#elseif canImport(Glibc)
  private let systemWaitPID = Glibc.waitpid
  private let systemWrite = Glibc.write
  private let systemRead = Glibc.read
#endif

#if os(Windows)
  private final class BlockingReadResult: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storage: Data?

    var value: Data? {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }

    func set(_ value: Data) {
      lock.lock()
      storage = value
      lock.unlock()
      semaphore.signal()
    }

    func wait(milliseconds: Int) -> Bool {
      semaphore.wait(timeout: .now() + .milliseconds(milliseconds)) == .success
    }
  }
#endif

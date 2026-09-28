import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif os(Windows)
  import WinSDK
#endif

struct BoundedProcessChild {
  #if os(Windows)
    let pid: Int32
    var processHandle: HANDLE
    private var outputHandle: HANDLE
    private var errorHandle: HANDLE
    private var standardOutput: BoundedByteBuffer
    private var standardError: BoundedByteBuffer

    init(
      pid: Int32,
      processHandle: HANDLE,
      outputHandle: HANDLE,
      errorHandle: HANDLE,
      maximumStandardOutputBytes: Int,
      maximumStandardErrorBytes: Int
    ) {
      self.pid = pid
      self.processHandle = processHandle
      self.outputHandle = outputHandle
      self.errorHandle = errorHandle
      standardOutput = BoundedByteBuffer(limit: maximumStandardOutputBytes)
      standardError = BoundedByteBuffer(limit: maximumStandardErrorBytes)
    }

    var outputExceededLimit: Bool {
      standardOutput.isTruncated || standardError.isTruncated
    }

    mutating func drainOutput() {
      Self.drain(handle: &outputHandle, into: &standardOutput, maximumChunks: 16)
      Self.drain(handle: &errorHandle, into: &standardError, maximumChunks: 16)
    }

    mutating func drainAfterExit() {
      Self.drain(handle: &outputHandle, into: &standardOutput, maximumChunks: .max)
      Self.drain(handle: &errorHandle, into: &standardError, maximumChunks: .max)
      closeHandles()
    }

    func requestTermination() {
      _ = TerminateProcess(processHandle, 1)
    }

    func forceTermination() {
      _ = TerminateProcess(processHandle, 1)
    }

    mutating func pollExit() throws -> Int32? {
      let wait = WaitForSingleObject(processHandle, 0)
      if wait == WAIT_OBJECT_0 {
        var code: DWORD = 0
        guard GetExitCodeProcess(processHandle, &code) else {
          throw BoundedProcessError.waitFailed
        }
        return Int32(bitPattern: code)
      }
      if wait == WAIT_TIMEOUT { return nil }
      throw BoundedProcessError.waitFailed
    }

    func result(termination: BoundedProcessTermination) -> BoundedProcessResult {
      BoundedProcessResult(
        termination: termination,
        standardOutput: standardOutput.data,
        standardError: standardError.data,
        standardOutputTruncated: standardOutput.isTruncated,
        standardErrorTruncated: standardError.isTruncated
      )
    }

    private mutating func closeHandles() {
      for handle in [processHandle, outputHandle, errorHandle]
      where handle != INVALID_HANDLE_VALUE {
        _ = CloseHandle(handle)
      }
      processHandle = INVALID_HANDLE_VALUE
      outputHandle = INVALID_HANDLE_VALUE
      errorHandle = INVALID_HANDLE_VALUE
    }

    private static func drain(
      handle: inout HANDLE,
      into buffer: inout BoundedByteBuffer,
      maximumChunks: Int
    ) {
      guard handle != INVALID_HANDLE_VALUE else { return }
      var chunks = 0
      var bytes = [UInt8](repeating: 0, count: 16 * 1_024)
      while chunks < maximumChunks {
        var available: DWORD = 0
        guard PeekNamedPipe(handle, nil, 0, nil, &available, nil) else {
          _ = CloseHandle(handle)
          handle = INVALID_HANDLE_VALUE
          return
        }
        guard available > 0 else { return }
        var received: DWORD = 0
        let requested = min(available, DWORD(bytes.count))
        let succeeded = bytes.withUnsafeMutableBytes { raw in
          ReadFile(handle, raw.baseAddress, requested, &received, nil)
        }
        if succeeded, received > 0 {
          buffer.append(Data(bytes.prefix(Int(received))))
          chunks += 1
          continue
        }
        _ = CloseHandle(handle)
        handle = INVALID_HANDLE_VALUE
        return
      }
    }
  #else
    let pid: pid_t
    private var outputDescriptor: Int32
    private var errorDescriptor: Int32
    private var standardOutput: BoundedByteBuffer
    private var standardError: BoundedByteBuffer

    init(
      pid: pid_t,
      outputDescriptor: Int32,
      errorDescriptor: Int32,
      maximumStandardOutputBytes: Int,
      maximumStandardErrorBytes: Int
    ) {
      self.pid = pid
      self.outputDescriptor = outputDescriptor
      self.errorDescriptor = errorDescriptor
      standardOutput = BoundedByteBuffer(limit: maximumStandardOutputBytes)
      standardError = BoundedByteBuffer(limit: maximumStandardErrorBytes)
    }

    var outputExceededLimit: Bool {
      standardOutput.isTruncated || standardError.isTruncated
    }

    mutating func drainOutput() {
      Self.drain(descriptor: &outputDescriptor, into: &standardOutput, maximumChunks: 16)
      Self.drain(descriptor: &errorDescriptor, into: &standardError, maximumChunks: 16)
    }

    mutating func drainAfterExit() {
      Self.drain(descriptor: &outputDescriptor, into: &standardOutput, maximumChunks: .max)
      Self.drain(descriptor: &errorDescriptor, into: &standardError, maximumChunks: .max)
      closeDescriptors()
    }

    func requestTermination() {
      _ = Darwin.kill(pid, SIGTERM)
    }

    func forceTermination() {
      _ = Darwin.kill(pid, SIGKILL)
    }

    mutating func pollExit() throws -> Int32? {
      var status: Int32 = 0
      var result: pid_t = -1
      repeat {
        result = waitpid(pid, &status, WNOHANG)
      } while result < 0 && errno == EINTR
      if result == 0 { return nil }
      if result < 0, errno == ECHILD { return 255 }
      guard result == pid else { throw BoundedProcessError.waitFailed }
      return Self.exitCode(status)
    }

    func result(termination: BoundedProcessTermination) -> BoundedProcessResult {
      BoundedProcessResult(
        termination: termination,
        standardOutput: standardOutput.data,
        standardError: standardError.data,
        standardOutputTruncated: standardOutput.isTruncated,
        standardErrorTruncated: standardError.isTruncated
      )
    }

    private static func drain(
      descriptor: inout Int32,
      into buffer: inout BoundedByteBuffer,
      maximumChunks: Int
    ) {
      guard descriptor >= 0 else { return }
      var bytes = [UInt8](repeating: 0, count: 16 * 1_024)
      var chunks = 0
      while chunks < maximumChunks {
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count > 0 {
          buffer.append(Data(bytes.prefix(count)))
          chunks += 1
          continue
        }
        if count == 0 {
          Darwin.close(descriptor)
          descriptor = -1
          return
        }
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK { return }
        Darwin.close(descriptor)
        descriptor = -1
        return
      }
    }

    private mutating func closeDescriptors() {
      if outputDescriptor >= 0 { Darwin.close(outputDescriptor) }
      if errorDescriptor >= 0 { Darwin.close(errorDescriptor) }
      outputDescriptor = -1
      errorDescriptor = -1
    }

    private static func exitCode(_ status: Int32) -> Int32 {
      let signal = status & 0x7f
      if signal == 0 { return (status >> 8) & 0xff }
      if signal != 0x7f { return 128 + signal }
      return status
    }
  #endif
}

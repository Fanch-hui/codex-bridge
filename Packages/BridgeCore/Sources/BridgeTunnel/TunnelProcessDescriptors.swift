import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

#if !os(Windows)
  final class TunnelDescriptorPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var readValue: Int32
    private var writeValue: Int32

    init() throws {
      var descriptors: [Int32] = [0, 0]
      let status = descriptors.withUnsafeMutableBufferPointer { pipe($0.baseAddress!) }
      guard status == 0 else { throw TunnelManagerError.launchFailed }
      readValue = fcntl(descriptors[0], F_DUPFD_CLOEXEC, 10)
      writeValue = fcntl(descriptors[1], F_DUPFD_CLOEXEC, 10)
      close(descriptors[0])
      close(descriptors[1])
      guard readValue >= 10, writeValue >= 10 else {
        closeRead()
        closeWrite()
        throw TunnelManagerError.launchFailed
      }
    }

    deinit {
      closeRead()
      closeWrite()
    }

    var readDescriptor: Int32 { lock.withLock { readValue } }
    var writeDescriptor: Int32 { lock.withLock { writeValue } }

    func takeRead() -> Int32 {
      lock.withLock {
        let descriptor = readValue
        readValue = -1
        return descriptor
      }
    }

    func closeRead() {
      lock.withLock {
        guard readValue >= 0 else { return }
        close(readValue)
        readValue = -1
      }
    }

    func closeWrite() {
      lock.withLock {
        guard writeValue >= 0 else { return }
        close(writeValue)
        writeValue = -1
      }
    }
  }

  final class TunnelDescriptorReader: @unchecked Sendable {
    private let descriptor: Int32
    private let buffer: RedactedOutputBuffer
    private let completion = NSCondition()
    private var finished = false

    init(descriptor: Int32, buffer: RedactedOutputBuffer) {
      self.descriptor = descriptor
      self.buffer = buffer
    }

    func start() {
      Thread.detachNewThread { [self] in
        readUntilEOF()
      }
    }

    func finish() {
      completion.lock()
      defer { completion.unlock() }
      while !finished {
        completion.wait()
      }
    }

    private func readUntilEOF() {
      // One reader owns draining and closing the pipe, including the EOF path.
      // Corelibs FileHandle.close() synchronizes with its readability callback queue.
      var bytes = [UInt8](repeating: 0, count: 16 * 1_024)
      while true {
        let count = bytes.withUnsafeMutableBytes { raw in
          #if os(Linux)
            Glibc.read(descriptor, raw.baseAddress, raw.count)
          #else
            Darwin.read(descriptor, raw.baseAddress, raw.count)
          #endif
        }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { break }
        buffer.append(Data(bytes.prefix(count)))
      }
      buffer.finish()
      close(descriptor)
      completion.lock()
      finished = true
      completion.broadcast()
      completion.unlock()
    }
  }
#endif

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
    private let fileHandle: FileHandle
    private let buffer: RedactedOutputBuffer
    private let lock = NSLock()
    private var finished = false

    init(descriptor: Int32, buffer: RedactedOutputBuffer) {
      fileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      self.buffer = buffer
    }

    func start() {
      fileHandle.readabilityHandler = { [weak self] handle in
        let data = handle.availableData
        guard !data.isEmpty else {
          self?.finish()
          return
        }
        self?.buffer.append(data)
      }
    }

    func finish() {
      lock.withLock {
        guard !finished else { return }
        finished = true
        fileHandle.readabilityHandler = nil
        buffer.append(fileHandle.readDataToEndOfFile())
        buffer.finish()
        try? fileHandle.close()
      }
    }
  }
#endif

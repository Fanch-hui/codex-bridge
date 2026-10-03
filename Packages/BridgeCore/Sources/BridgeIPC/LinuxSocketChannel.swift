#if os(Linux)
  import Foundation
  import Glibc

  public final class LinuxSocketChannel: @unchecked Sendable {
    public let descriptor: Int32
    private let condition = NSCondition()
    private let writeLock = NSLock()
    private var closed = false
    private var transfers = 0
    private var descriptorClosed = false

    public init(descriptor: Int32) {
      self.descriptor = descriptor
    }

    deinit { close() }

    public static func createDescriptor() throws -> Int32 {
      let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue), 0)
      guard descriptor >= 0 else { throw LinuxSocketError.system(errno) }
      return descriptor
    }

    public static func withAddress<Result>(
      path: String, operation: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
    ) throws -> Result {
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      let bytes = Array(path.utf8) + [0]
      guard !path.contains("\0"), bytes.count <= MemoryLayout.size(ofValue: address.sun_path)
      else { throw LinuxSocketError.invalidPath }
      withUnsafeMutableBytes(of: &address.sun_path) { target in
        target.copyBytes(from: bytes)
      }
      return try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          try operation($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
    }

    public static func connect(path: String) throws -> LinuxSocketChannel {
      let descriptor = try createDescriptor()
      do {
        try withAddress(path: path) { address, length in
          guard Glibc.connect(descriptor, address, length) == 0 else {
            throw LinuxSocketError.system(errno)
          }
        }
        return LinuxSocketChannel(descriptor: descriptor)
      } catch {
        _ = Glibc.close(descriptor)
        throw error
      }
    }

    public func writeFrame(
      kind: UInt8, payload: Data, register: () throws -> Void = {}
    ) throws {
      guard payload.count <= BridgeServiceIPC.maximumMessageBytes else {
        throw LinuxSocketError.invalidFrame
      }
      writeLock.lock()
      defer { writeLock.unlock() }
      try beginTransfer()
      defer { endTransfer() }
      try register()
      var frame = Data([kind])
      var length = UInt32(payload.count).littleEndian
      withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
      frame.append(payload)
      try frame.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          let count = send(
            descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset,
            Int32(MSG_NOSIGNAL))
          if count < 0, errno == EINTR { continue }
          guard count > 0 else { throw LinuxSocketError.closed }
          offset += count
        }
      }
    }

    public func readFrame() throws -> (kind: UInt8, payload: Data) {
      let header = try readFully(5)
      let length = header.withUnsafeBytes {
        $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self).littleEndian
      }
      guard length <= BridgeServiceIPC.maximumMessageBytes else {
        throw LinuxSocketError.invalidFrame
      }
      return (header[0], try readFully(Int(length)))
    }

    private func readFully(_ count: Int) throws -> Data {
      try beginTransfer()
      defer { endTransfer() }
      var data = Data(count: count)
      try data.withUnsafeMutableBytes { bytes in
        var offset = 0
        while offset < count {
          let received = recv(
            descriptor, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
          if received < 0, errno == EINTR { continue }
          guard received > 0 else { throw LinuxSocketError.closed }
          offset += received
        }
      }
      return data
    }

    private func beginTransfer() throws {
      condition.lock()
      defer { condition.unlock() }
      guard !closed else { throw LinuxSocketError.closed }
      transfers += 1
    }

    private func endTransfer() {
      condition.lock()
      transfers -= 1
      if transfers == 0 { condition.broadcast() }
      condition.unlock()
    }

    public func close() {
      condition.lock()
      if !closed {
        closed = true
        _ = shutdown(descriptor, Int32(SHUT_RDWR))
      }
      while transfers > 0 { condition.wait() }
      if !descriptorClosed {
        descriptorClosed = true
        _ = Glibc.close(descriptor)
      }
      condition.unlock()
    }
  }
#endif

#if os(macOS)
  import Darwin
  import Dispatch
  import Foundation

  /// One bounded request and response over an authenticated local socket.
  public final class MacLocalMCPChannel: @unchecked Sendable {
    public static let maximumFrameBytes = 64 * 1_024
    public let descriptor: Int32

    private let condition = NSCondition()
    private let readLock = NSLock()
    private let writeLock = NSLock()
    private var closed = false
    private var descriptorClosed = false
    private var transfers = 0

    public init(descriptor: Int32) throws {
      try Self.configure(descriptor)
      self.descriptor = descriptor
    }

    deinit { close() }

    public static func createDescriptor() throws -> Int32 {
      let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
      guard descriptor >= 0 else { throw MacLocalMCPError.system(errno) }
      do {
        try configure(descriptor)
        return descriptor
      } catch {
        _ = Darwin.close(descriptor)
        throw error
      }
    }

    public static func withAddress<Result>(
      path: String, operation: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
    ) throws -> Result {
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      let bytes = Array(path.utf8) + [0]
      guard path.hasPrefix("/"), !path.contains("\0"),
        bytes.count <= MemoryLayout.size(ofValue: address.sun_path)
      else { throw MacLocalMCPError.invalidPath }
      address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
      withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
      return try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          try operation($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
    }

    public static func connect(path: String) throws -> MacLocalMCPChannel {
      let descriptor = try createDescriptor()
      do {
        try withAddress(path: path) { address, length in
          let result = Darwin.connect(descriptor, address, length)
          if result == 0 { return }
          guard errno == EINPROGRESS || errno == EAGAIN else {
            throw MacLocalMCPError.system(errno)
          }
          try wait(descriptor, event: Int16(POLLOUT), deadline: deadline())
          var socketError: Int32 = 0
          var size = socklen_t(MemoryLayout<Int32>.size)
          guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0 else {
            throw MacLocalMCPError.system(errno)
          }
          guard socketError == 0 else { throw MacLocalMCPError.system(socketError) }
        }
        return try MacLocalMCPChannel(descriptor: descriptor)
      } catch {
        _ = Darwin.close(descriptor)
        throw error
      }
    }

    public func readFrame(timeoutSeconds: UInt64 = 5) throws -> Data {
      precondition((1...120).contains(timeoutSeconds))
      readLock.lock()
      defer { readLock.unlock() }
      try beginTransfer()
      defer { endTransfer() }
      let limit = Self.deadline(timeoutSeconds: timeoutSeconds)
      let header = try read(4, deadline: limit)
      let count = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
      guard count > 0, count <= Self.maximumFrameBytes else { throw MacLocalMCPError.invalidFrame }
      return try read(Int(count), deadline: limit)
    }

    public func writeFrame(_ payload: Data) throws {
      guard !payload.isEmpty, payload.count <= Self.maximumFrameBytes else {
        throw MacLocalMCPError.invalidFrame
      }
      writeLock.lock()
      defer { writeLock.unlock() }
      try beginTransfer()
      defer { endTransfer() }
      var size = UInt32(payload.count).bigEndian
      var frame = withUnsafeBytes(of: &size) { Data($0) }
      frame.append(payload)
      let limit = Self.deadline()
      try frame.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          try Self.wait(descriptor, event: Int16(POLLOUT), deadline: limit)
          let count = send(
            descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
          if count < 0, errno == EINTR || errno == EAGAIN { continue }
          guard count > 0 else { throw MacLocalMCPError.closed }
          offset += count
        }
      }
    }

    public func close() {
      condition.lock()
      if !closed {
        closed = true
        _ = shutdown(descriptor, SHUT_RDWR)
      }
      while transfers > 0 { condition.wait() }
      if !descriptorClosed {
        descriptorClosed = true
        _ = Darwin.close(descriptor)
      }
      condition.unlock()
    }

    private func read(_ count: Int, deadline: UInt64) throws -> Data {
      var data = Data(count: count)
      try data.withUnsafeMutableBytes { bytes in
        var offset = 0
        while offset < count {
          try Self.wait(descriptor, event: Int16(POLLIN), deadline: deadline)
          let received = recv(
            descriptor, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
          if received < 0, errno == EINTR || errno == EAGAIN { continue }
          guard received > 0 else { throw MacLocalMCPError.closed }
          offset += received
        }
      }
      return data
    }

    private func beginTransfer() throws {
      condition.lock()
      defer { condition.unlock() }
      guard !closed else { throw MacLocalMCPError.closed }
      transfers += 1
    }

    private func endTransfer() {
      condition.lock()
      transfers -= 1
      if transfers == 0 { condition.broadcast() }
      condition.unlock()
    }

    private static func configure(_ descriptor: Int32) throws {
      let flags = fcntl(descriptor, F_GETFL)
      guard flags >= 0,
        fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
        fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0
      else { throw MacLocalMCPError.system(errno) }
      var enabled: Int32 = 1
      guard
        setsockopt(
          descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
          socklen_t(MemoryLayout<Int32>.size)) == 0
      else { throw MacLocalMCPError.system(errno) }
    }

    private static func deadline(timeoutSeconds: UInt64 = 5) -> UInt64 {
      DispatchTime.now().uptimeNanoseconds + timeoutSeconds * 1_000_000_000
    }

    private static func wait(_ descriptor: Int32, event: Int16, deadline: UInt64) throws {
      while true {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { throw MacLocalMCPError.timeout }
        let remaining = deadline - now
        let milliseconds = Int32((remaining + 999_999) / 1_000_000)
        var state = pollfd(fd: descriptor, events: event, revents: 0)
        let result = poll(&state, 1, milliseconds)
        if result < 0, errno == EINTR { continue }
        guard result >= 0 else { throw MacLocalMCPError.system(errno) }
        guard result != 0 else { throw MacLocalMCPError.timeout }
        if state.revents & event != 0 { return }
        if state.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
          throw MacLocalMCPError.closed
        }
      }
    }
  }
#endif

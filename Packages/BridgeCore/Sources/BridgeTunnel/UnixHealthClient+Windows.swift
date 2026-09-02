#if os(Windows)
  import Foundation
  import WinSDK

  /// Winsock HTTP plumbing for the loopback health channel. The tunnel helper
  /// binds 127.0.0.1, so only the IPv4 TCP table is queried for ownership.
  enum WindowsHealthSocket {
    private static let bootstrapError: Int32 = {
      var data = WSADATA()
      return WSAStartup(0x0202, &data)
    }()

    static func request(
      path: String,
      baseURL: URL,
      maximumResponseBytes: Int
    ) throws -> HTTPResponse {
      guard bootstrapError == 0 else { throw TunnelHealthError.unavailable }
      guard let port = baseURL.port else { throw TunnelHealthError.invalidURLFile }
      let descriptor = socket(AF_INET, SOCK_STREAM, Int32(IPPROTO_TCP.rawValue))
      guard descriptor != INVALID_SOCKET else { throw TunnelHealthError.unavailable }
      defer { _ = closesocket(descriptor) }
      try setTimeout(descriptor)
      try connect(descriptor, port: port)
      let request = Data(
        "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n".utf8
      )
      try write(request, to: descriptor)
      return try readResponse(from: descriptor, maximumResponseBytes: maximumResponseBytes)
    }

    private static func setTimeout(_ descriptor: SOCKET) throws {
      var timeout = DWORD(2_000)
      let size = DWORD(MemoryLayout<DWORD>.size)
      let configured = withUnsafePointer(to: &timeout) { pointer in
        let raw = UnsafeRawPointer(pointer)
        return setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, raw, Int32(size)) == 0
          && setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, raw, Int32(size)) == 0
      }
      guard configured else { throw TunnelHealthError.unavailable }
    }

    private static func connect(_ descriptor: SOCKET, port: Int) throws {
      var address = sockaddr_in()
      address.sin_family = ADDRESS_FAMILY(AF_INET)
      address.sin_port = UInt16(port).bigEndian
      guard inet_pton(Int32(AF_INET), "127.0.0.1", &address.sin_addr) == 1 else {
        throw TunnelHealthError.unavailable
      }
      let status = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          WinSDK.connect(descriptor, $0, Int32(MemoryLayout<sockaddr_in>.size))
        }
      }
      guard status == 0 else { throw TunnelHealthError.unavailable }
    }

    private static func write(_ data: Data, to descriptor: SOCKET) throws {
      try data.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
          let count = WinSDK.send(
            descriptor,
            baseAddress.advanced(by: offset),
            Int32(bytes.count - offset),
            0
          )
          guard count > 0 else { throw TunnelHealthError.unavailable }
          offset += Int(count)
        }
      }
    }

    private static func readResponse(
      from descriptor: SOCKET,
      maximumResponseBytes: Int
    ) throws -> HTTPResponse {
      var response = Data()
      var chunk = [UInt8](repeating: 0, count: 16_384)
      while response.count <= maximumResponseBytes {
        let count = chunk.withUnsafeMutableBytes { raw in
          WinSDK.recv(descriptor, raw.baseAddress, Int32(raw.count), 0)
        }
        if count == 0 { break }
        guard count > 0 else {
          let error = WSAGetLastError()
          guard error == WSAETIMEDOUT || error == WSAEWOULDBLOCK else {
            throw TunnelHealthError.unavailable
          }
          break
        }
        response.append(chunk, count: Int(count))
      }
      guard response.count <= maximumResponseBytes else {
        throw TunnelHealthError.responseTooLarge
      }
      guard !response.isEmpty else {
        throw TunnelHealthError.invalidResponse
      }
      return try HTTPResponse(data: response)
    }
  }

  /// Queries the IPv4 TCP owner table for a listening port owned by the
  /// expected process, mirroring the macOS proc_pidinfo port-owner check.
  enum WindowsHealthPortOwner {
    static func owns(port: Int, processID: Int32) -> Bool {
      guard port > 0, port <= 65_535, processID > 0 else { return false }
      var size: DWORD = 0
      guard
        GetExtendedTcpTable(nil, &size, false, ULONG(AF_INET), TCP_TABLE_OWNER_PID_ALL, 0)
          == ERROR_INSUFFICIENT_BUFFER,
        size >= MemoryLayout<MIB_TCPTABLE_OWNER_PID>.size
      else { return false }
      let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(size))
      defer { bytes.deallocate() }
      guard
        GetExtendedTcpTable(bytes, &size, false, ULONG(AF_INET), TCP_TABLE_OWNER_PID_ALL, 0) == 0
      else { return false }
      let rowOffset = MemoryLayout<MIB_TCPTABLE_OWNER_PID>.offset(of: \.table) ?? 4
      let count = Int(bytes.withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee })
      let rows = UnsafeMutableRawPointer(bytes.advanced(by: rowOffset)).assumingMemoryBound(
        to: MIB_TCPROW_OWNER_PID.self
      )
      for index in 0..<count {
        let row = rows[index]
        guard
          row.dwState == MIB_TCP_STATE_LISTEN.rawValue,
          ntohs(UInt16(truncatingIfNeeded: row.dwLocalPort)) == UInt16(port),
          row.dwOwningPid == DWORD(bitPattern: processID)
        else { continue }
        return true
      }
      return false
    }
  }
#endif

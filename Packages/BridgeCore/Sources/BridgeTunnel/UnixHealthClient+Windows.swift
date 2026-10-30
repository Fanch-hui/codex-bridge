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
      guard bootstrapError == 0 else {
        throw TunnelHealthError.socketFailed(operation: .startup, code: bootstrapError)
      }
      guard let port = baseURL.port else { throw TunnelHealthError.invalidURLFile }
      let descriptor = socket(AF_INET, SOCK_STREAM, Int32(IPPROTO_TCP.rawValue))
      guard descriptor != INVALID_SOCKET else {
        throw TunnelHealthError.socketFailed(operation: .create, code: WSAGetLastError())
      }
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
      guard configured else {
        throw TunnelHealthError.socketFailed(operation: .configure, code: WSAGetLastError())
      }
    }

    private static func connect(_ descriptor: SOCKET, port: Int) throws {
      var address = sockaddr_in()
      address.sin_family = ADDRESS_FAMILY(AF_INET)
      address.sin_port = UInt16(port).bigEndian
      guard inet_pton(Int32(AF_INET), "127.0.0.1", &address.sin_addr) == 1 else {
        throw TunnelHealthError.socketFailed(operation: .connect, code: WSAGetLastError())
      }
      let status = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          WinSDK.connect(descriptor, $0, Int32(MemoryLayout<sockaddr_in>.size))
        }
      }
      guard status == 0 else {
        throw TunnelHealthError.socketFailed(operation: .connect, code: WSAGetLastError())
      }
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
          guard count > 0 else {
            throw TunnelHealthError.socketFailed(operation: .send, code: WSAGetLastError())
          }
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
            throw TunnelHealthError.socketFailed(operation: .receive, code: error)
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

#endif

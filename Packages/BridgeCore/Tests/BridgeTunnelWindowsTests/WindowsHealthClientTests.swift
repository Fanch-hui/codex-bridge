import Foundation
import WinSDK
import XCTest

@testable import BridgeTunnel

final class WindowsHealthClientTests: XCTestCase {
  private var listener: TestHTTPListener!

  override func tearDownWithError() throws {
    listener = nil
  }

  func testRequestParsesLoopbackHTTPResponse() throws {
    listener = try TestHTTPListener(body: "ready")
    let baseURL = URL(string: "http://127.0.0.1:\(listener.port)")!
    let response = try WindowsHealthSocket.request(
      path: "/readyz",
      baseURL: baseURL,
      maximumResponseBytes: 1024 * 1024
    )
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "ready")
  }

  func testRequestFailsWhenNothingListens() {
    let baseURL = URL(string: "http://127.0.0.1:1")!
    XCTAssertThrowsError(
      try WindowsHealthSocket.request(
        path: "/readyz",
        baseURL: baseURL,
        maximumResponseBytes: 1024 * 1024
      )
    ) { error in
      XCTAssertEqual(error as? TunnelHealthError, .unavailable)
    }
  }

  func testPortOwnerMatchesListeningProcess() throws {
    listener = try TestHTTPListener(body: "ready")
    XCTAssertTrue(
      WindowsHealthPortOwner.owns(
        port: listener.port,
        processID: Int32(bitPattern: GetCurrentProcessId())
      )
    )
    XCTAssertFalse(WindowsHealthPortOwner.owns(port: listener.port, processID: 1))
    XCTAssertFalse(WindowsHealthPortOwner.owns(port: 65_535, processID: 1))
  }
}

private final class TestHTTPListener {
  let port: Int
  private let socket: SOCKET
  private let body: String
  private let thread: Thread

  init(body: String) throws {
    self.body = body
    var data = WSADATA()
    _ = WSAStartup(0x0202, &data)
    let descriptor = WinSDK.socket(AF_INET, SOCK_STREAM, Int32(IPPROTO_TCP.rawValue))
    guard descriptor != INVALID_SOCKET else { throw TunnelHealthError.unavailable }
    var address = sockaddr_in()
    address.sin_family = ADDRESS_FAMILY(AF_INET)
    address.sin_port = 0
    guard inet_pton(Int32(AF_INET), "127.0.0.1", &address.sin_addr) == 1,
      withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          WinSDK.bind(descriptor, $0, Int32(MemoryLayout<sockaddr_in>.size))
        }
      } == 0,
      WinSDK.listen(descriptor, 1) == 0
    else {
      _ = closesocket(descriptor)
      throw TunnelHealthError.unavailable
    }
    var length = Int32(MemoryLayout<sockaddr_in>.size)
    var bound = sockaddr_in()
    let gotName = withUnsafeMutablePointer(to: &bound) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        WinSDK.getsockname(descriptor, $0, &length)
      }
    }
    guard gotName == 0 else {
      _ = closesocket(descriptor)
      throw TunnelHealthError.unavailable
    }
    socket = descriptor
    port = Int(bound.sin_port.bigEndian)
    let acceptedSocket = socket
    let responseBody = body
    thread = Thread {
      Self.acceptAndRespond(socket: acceptedSocket, body: responseBody)
    }
    thread.start()
  }

  deinit {
    _ = closesocket(socket)
  }

  private static func acceptAndRespond(socket: SOCKET, body: String) {
    let accepted = WinSDK.accept(socket, nil, nil)
    guard accepted != INVALID_SOCKET else { return }
    defer { _ = closesocket(accepted) }
    var request = Data()
    var chunk = [UInt8](repeating: 0, count: 4_096)
    while request.range(of: Data("\r\n\r\n".utf8)) == nil {
      let count = chunk.withUnsafeMutableBytes { raw in
        WinSDK.recv(accepted, raw.baseAddress, Int32(raw.count), 0)
      }
      guard count > 0 else { break }
      request.append(chunk, count: Int(count))
    }
    let response = Data(
      "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        .utf8
    )
    response.withUnsafeBytes { raw in
      _ = WinSDK.send(accepted, raw.baseAddress, Int32(raw.count), 0)
    }
  }
}

import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1

/// The handler awaits each send before producing the next chunk.
public actor ModelGatewayResponseSink {
  private enum State { case waiting, streaming, finished }
  private let channel: any Channel
  private let version: HTTPVersion
  private let maximumChunkBytes: Int
  private var state = State.waiting
  public private(set) var sendsEvents = false
  private var writing = false
  private var lastData: ContinuousClock.Instant?

  init(channel: any Channel, version: HTTPVersion, maximumChunkBytes: Int) {
    self.channel = channel
    self.version = version
    self.maximumChunkBytes = maximumChunkBytes
  }

  public func sendHead(status: Int, headers: [String: String] = [:]) async throws {
    guard case .waiting = state else { throw ModelGatewayError.responseAlreadyStarted }
    guard (200...599).contains(status), status != 204, status != 304 else {
      throw ModelGatewayError.invalidResponse
    }
    var head = HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: status))
    for (name, value) in headers {
      guard Self.validHeaderName(name), !value.contains("\r"), !value.contains("\n") else {
        throw ModelGatewayError.invalidResponse
      }
      guard !["connection", "content-length", "transfer-encoding"].contains(name.lowercased())
      else { continue }
      head.headers.add(name: name, value: value)
    }
    head.headers.replaceOrAdd(name: "Connection", value: "close")
    if version == .http1_1 {
      head.headers.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
    }
    sendsEvents =
      head.headers.first(name: "content-type")?.lowercased().hasPrefix("text/event-stream") == true
    state = .streaming
    try Task.checkCancellation()
    guard channel.isActive else { throw ModelGatewayError.channelClosed }
    try await channel.writeAndFlush(HTTPServerResponsePart.head(head)).get()
  }

  public func send(_ data: Data) async throws {
    guard case .streaming = state else {
      if case .waiting = state { throw ModelGatewayError.responseNotStarted }
      throw ModelGatewayError.responseFinished
    }
    guard !writing else { throw ModelGatewayError.invalidResponse }
    guard data.count <= maximumChunkBytes else { throw ModelGatewayError.responseChunkTooLarge }
    try Task.checkCancellation()
    guard channel.isActive else { throw ModelGatewayError.channelClosed }
    guard !data.isEmpty else { return }
    writing = true
    defer { writing = false }
    var buffer = channel.allocator.buffer(capacity: data.count)
    buffer.writeBytes(data)
    try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))).get()
    lastData = .now
  }

  /// Measures silence on the client-visible stream, including the wait for its first byte.
  public func waitForStreamSilence(_ interval: Duration) async throws {
    let start = ContinuousClock.now
    while true {
      let end = (lastData ?? start).advanced(by: interval)
      if ContinuousClock.now >= end { return }
      try await ContinuousClock().sleep(until: end)
    }
  }

  func finish() async throws {
    guard case .streaming = state, !writing else { throw ModelGatewayError.responseNotStarted }
    state = .finished
    try Task.checkCancellation()
    guard channel.isActive else { throw ModelGatewayError.channelClosed }
    try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
  }

  public var hasStarted: Bool {
    if case .waiting = state { return false }
    return true
  }

  private static func validHeaderName(_ name: String) -> Bool {
    !name.isEmpty
      && name.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
          || [33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126].contains(byte)
      }
  }
}

import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOWebSocket

public enum ModelGatewayWebSocketMessage: Sendable, Equatable {
  case text(String)
  case binary(Data)
}

public typealias ModelGatewayWebSocketSession = @Sendable (ModelGatewayWebSocket) async -> Void

public enum ModelGatewayWebSocketAcceptance: Sendable {
  /// Answers the upgrade with a plain HTTP status; 426 asks Codex to use HTTP for the session.
  case reject(status: Int)
  case accept(headers: [String: String], session: ModelGatewayWebSocketSession)
}

/// Decides one upgrade request after transport authentication; the request has an empty body.
public typealias ModelGatewayWebSocketHandler =
  @Sendable (ModelGatewayRequest) async -> ModelGatewayWebSocketAcceptance

/// The client side of one accepted WebSocket connection. Messages arrive reassembled.
public final class ModelGatewayWebSocket: Sendable {
  public let messages: AsyncStream<ModelGatewayWebSocketMessage>
  private let channel: any Channel

  init(channel: any Channel, messages: AsyncStream<ModelGatewayWebSocketMessage>) {
    self.channel = channel
    self.messages = messages
  }

  public func send(_ message: ModelGatewayWebSocketMessage) async throws {
    guard channel.isActive else { throw ModelGatewayError.channelClosed }
    let frame: WebSocketFrame
    switch message {
    case .text(let text):
      var buffer = channel.allocator.buffer(capacity: text.utf8.count)
      buffer.writeString(text)
      frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
    case .binary(let data):
      var buffer = channel.allocator.buffer(capacity: data.count)
      buffer.writeBytes(data)
      frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
    }
    try await channel.writeAndFlush(frame).get()
  }

  /// Sends a close frame with `code` and closes the connection.
  public func close(code: Int) async {
    guard channel.isActive else { return }
    var data = channel.allocator.buffer(capacity: 2)
    data.write(webSocketErrorCode: WebSocketErrorCode(codeNumber: code))
    try? await channel.writeAndFlush(
      WebSocketFrame(fin: true, opcode: .connectionClose, data: data)
    ).get()
    try? await channel.close().get()
  }
}

/// Carries the upgrade decision from the upgrader to the pipeline that runs after it.
final class ModelGatewayUpgradeState: @unchecked Sendable {
  private let lock = NSLock()
  private var rejectedStatus: Int?
  private var session: ModelGatewayWebSocketSession?

  func reject(_ status: Int) { lock.withLock { rejectedStatus = status } }
  func accept(_ value: @escaping ModelGatewayWebSocketSession) { lock.withLock { session = value } }
  func takeRejectedStatus() -> Int? {
    lock.withLock {
      defer { rejectedStatus = nil }
      return rejectedStatus
    }
  }
  func takeSession() -> ModelGatewayWebSocketSession? {
    lock.withLock {
      defer { session = nil }
      return session
    }
  }
}

extension ModelGatewayHTTPHandler {
  static let handlerName = "model-gateway-http"

  static func webSocketUpgrader(
    configuration: ModelGatewayConfiguration, state: ModelGatewayUpgradeState,
    admission: ModelGatewayAdmission, authenticate: @escaping ModelGatewayAuthenticate,
    handler: ModelGatewayWebSocketHandler?
  ) -> NIOWebSocketServerUpgrader {
    NIOWebSocketServerUpgrader(
      maxFrameSize: configuration.maximumBodyBytes,
      shouldUpgrade: { channel, head in
        let promise = channel.eventLoop.makePromise(of: HTTPHeaders?.self)
        promise.completeWithTask {
          let status: Int
          switch checkUpgrade(head, channel: channel, authenticate: authenticate) {
          case .rejected(let rejected): status = rejected
          case .authenticated(let request):
            guard let handler else {
              status = 426
              break
            }
            switch await handler(request) {
            case .reject(let rejected): status = rejected
            case .accept(let headers, let session):
              var result = HTTPHeaders()
              for (name, value) in headers where !value.contains("\r") && !value.contains("\n") {
                result.add(name: name, value: value)
              }
              state.accept(session)
              return result
            }
          }
          state.reject((400...599).contains(status) ? status : 502)
          return nil
        }
        return promise.futureResult
      },
      upgradePipelineHandler: { channel, _ in
        guard let session = state.takeSession() else { return channel.close() }
        return channel.pipeline.removeHandler(name: handlerName).flatMap {
          channel.pipeline.addHandlers([
            NIOWebSocketFrameAggregator(
              minNonFinalFragmentSize: 0, maxAccumulatedFrameCount: 4096,
              maxAccumulatedFrameSize: configuration.maximumBodyBytes),
            ModelGatewayWebSocketFrameHandler(admission: admission, session: session),
          ])
        }
      })
  }

  private enum UpgradeCheck {
    case rejected(Int)
    case authenticated(ModelGatewayRequest)
  }

  private static func checkUpgrade(
    _ head: HTTPRequestHead, channel: any Channel, authenticate: ModelGatewayAuthenticate
  ) -> UpgradeCheck {
    guard head.method == .GET, head.uri == "/v1/responses" else { return .rejected(404) }
    guard validAuthority(head, channel: channel) else { return .rejected(403) }
    guard let client = authenticatedClient(head, authenticate: authenticate) else {
      return .rejected(401)
    }
    return .authenticated(
      makeRequest(
        Request(
          head: head, path: "/v1/responses", query: nil, client: client,
          bytes: channel.allocator.buffer(capacity: 0))))
  }
}

final class ModelGatewayWebSocketFrameHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = WebSocketFrame
  typealias OutboundOut = WebSocketFrame

  private let admission: ModelGatewayAdmission
  private let session: ModelGatewayWebSocketSession
  private var continuation: AsyncStream<ModelGatewayWebSocketMessage>.Continuation?
  private var task: Task<Void, Never>?

  init(admission: ModelGatewayAdmission, session: @escaping ModelGatewayWebSocketSession) {
    self.admission = admission
    self.session = session
  }

  func handlerAdded(context: ChannelHandlerContext) {
    let (messages, continuation) = AsyncStream.makeStream(of: ModelGatewayWebSocketMessage.self)
    self.continuation = continuation
    let socket = ModelGatewayWebSocket(channel: context.channel, messages: messages)
    let session = session
    task = Task {
      await session(socket)
      await socket.close(code: 1000)
    }
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let frame = unwrapInboundIn(data)
    switch frame.opcode {
    case .text:
      continuation?.yield(.text(String(buffer: frame.unmaskedData)))
    case .binary:
      continuation?.yield(.binary(Data(frame.unmaskedData.readableBytesView)))
    case .ping:
      let pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
      context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
    case .connectionClose:
      continuation?.finish()
      var data = frame.unmaskedData
      let code = data.readSlice(length: 2) ?? context.channel.allocator.buffer(capacity: 0)
      let reply = WebSocketFrame(fin: true, opcode: .connectionClose, data: code)
      context.writeAndFlush(wrapOutboundOut(reply)).whenComplete { _ in
        context.close(promise: nil)
      }
    default:
      break
    }
  }

  func channelInactive(context: ChannelHandlerContext) {
    continuation?.finish()
    continuation = nil
    task?.cancel()
    admission.unregister(context.channel)
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    continuation?.finish()
    context.close(promise: nil)
  }
}

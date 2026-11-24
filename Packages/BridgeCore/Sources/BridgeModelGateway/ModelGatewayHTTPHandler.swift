import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOWebSocket

final class ModelGatewayHTTPHandler: ChannelInboundHandler, RemovableChannelHandler,
  @unchecked Sendable
{
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  struct Request {
    let head: HTTPRequestHead
    let path: String
    let query: String?
    let client: ModelGatewayClientContext
    var bytes: ByteBuffer
  }

  private enum State {
    case waiting
    case receiving(Request)
    case responding, closed
  }
  private let configuration: ModelGatewayConfiguration
  private let admission: ModelGatewayAdmission
  private let authenticate: ModelGatewayAuthenticate
  private let handler: ModelGatewayRequestHandler
  private let upgradeState: ModelGatewayUpgradeState
  private var state = State.waiting
  private var lease: ModelGatewayLease?
  private var task: Task<Void, Never>?
  private var timeout: Scheduled<Void>?

  init(
    configuration: ModelGatewayConfiguration, admission: ModelGatewayAdmission,
    authenticate: @escaping ModelGatewayAuthenticate, handler: @escaping ModelGatewayRequestHandler,
    upgradeState: ModelGatewayUpgradeState
  ) {
    self.configuration = configuration
    self.admission = admission
    self.authenticate = authenticate
    self.handler = handler
    self.upgradeState = upgradeState
  }

  func handlerRemoved(context: ChannelHandlerContext) {
    timeout?.cancel()
  }

  func channelActive(context: ChannelHandlerContext) {
    scheduleTimeout(context: context, seconds: 15)
    context.fireChannelActive()
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head): receiveHead(head, context: context)
    case .body(var body): receiveBody(&body, context: context)
    case .end: receiveEnd(context: context)
    }
  }

  func channelInactive(context: ChannelHandlerContext) {
    timeout?.cancel()
    state = .closed
    task?.cancel()
    if task == nil {
      lease?.release()
      lease = nil
    }
    admission.unregister(context.channel)
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    // A refused upgrade is reported first; the request then arrives here to get its status.
    if error as? NIOWebSocketUpgradeError == .unsupportedWebSocketTarget { return }
    task?.cancel()
    context.close(promise: nil)
  }

  private func receiveHead(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
    guard case .waiting = state else {
      context.close(promise: nil)
      return
    }
    timeout?.cancel()
    if let status = upgradeState.takeRejectedStatus() {
      reject(HTTPResponseStatus(statusCode: status), context: context)
      return
    }
    guard let route = Self.parseRoute(uri: head.uri, method: head.method) else {
      reject(.notFound, context: context)
      return
    }
    guard Self.validAuthority(head, channel: context.channel) else {
      reject(.forbidden, context: context)
      return
    }
    guard let client = Self.authenticatedClient(head, authenticate: authenticate) else {
      reject(.unauthorized, context: context)
      return
    }
    if head.method == .HEAD, route.path == "/api/hello" {
      reject(.ok, context: context)
      return
    }
    guard let lease = admission.admit(context.channel) else {
      reject(.tooManyRequests, context: context)
      return
    }
    self.lease = lease
    guard Self.validLength(head.headers, maximum: configuration.maximumBodyBytes) else {
      reject(.payloadTooLarge, context: context)
      return
    }
    state = .receiving(
      Request(
        head: head, path: route.path, query: route.query, client: client,
        bytes: context.channel.allocator.buffer(capacity: 0)))
    scheduleTimeout(context: context, seconds: 60)
  }

  private func receiveBody(_ body: inout ByteBuffer, context: ChannelHandlerContext) {
    guard case .receiving(var request) = state else { return }
    let count = request.bytes.readableBytes.addingReportingOverflow(body.readableBytes)
    guard !count.overflow, count.partialValue <= configuration.maximumBodyBytes else {
      reject(.payloadTooLarge, context: context)
      return
    }
    request.bytes.writeBuffer(&body)
    state = .receiving(request)
  }

  private func receiveEnd(context: ChannelHandlerContext) {
    guard case .receiving(let request) = state, let lease else { return }
    timeout?.cancel()
    self.lease = nil
    state = .responding
    let channel = context.channel
    let handler = handler
    let sink = ModelGatewayResponseSink(
      channel: channel, version: request.head.version,
      maximumChunkBytes: configuration.maximumResponseChunkBytes)
    let gatewayRequest = Self.makeRequest(request)
    task = Task {
      defer { lease.release() }
      do {
        try await handler(gatewayRequest, sink)
        if !(await sink.hasStarted) {
          try await sink.sendHead(status: 500, headers: ["Content-Type": "application/json"])
          try await sink.send(Data("{\"error\":\"response_unavailable\"}".utf8))
        }
        try await sink.finish()
      } catch {
        if !Task.isCancelled, channel.isActive, !(await sink.hasStarted) {
          try? await sink.sendHead(status: 500, headers: ["Content-Type": "application/json"])
          try? await sink.send(Data("{\"error\":\"request_failed\"}".utf8))
          try? await sink.finish()
        }
      }
      try? await channel.close().get()
    }
  }

  private func reject(_ status: HTTPResponseStatus, context: ChannelHandlerContext) {
    timeout?.cancel()
    state = .closed
    lease?.release()
    lease = nil
    var head = HTTPResponseHead(version: .http1_1, status: status)
    head.headers.add(name: "Content-Length", value: "0")
    head.headers.add(name: "Connection", value: "close")
    let channel = context.channel
    context.write(wrapOutboundOut(.head(head)), promise: nil)
    context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
      channel.close(promise: nil)
    }
  }

  private func scheduleTimeout(context: ChannelHandlerContext, seconds: Int64) {
    timeout?.cancel()
    let channel = context.channel
    timeout = context.eventLoop.scheduleTask(in: .seconds(seconds)) { channel.close(promise: nil) }
  }
}

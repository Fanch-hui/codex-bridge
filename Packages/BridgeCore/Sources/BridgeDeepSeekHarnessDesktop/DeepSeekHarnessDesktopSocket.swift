import BridgeAgentCore
import Foundation
import NIOCore
import NIOPosix

public protocol DeepSeekHarnessDesktopTransport: Sendable {
  func send(_ data: Data) async throws
  func receive() async throws -> Data
  func close() async
}

public typealias DeepSeekHarnessDesktopTransportFactory =
  @Sendable (Int) async throws -> any DeepSeekHarnessDesktopTransport

public final class DeepSeekHarnessDesktopSocket: DeepSeekHarnessDesktopTransport,
  @unchecked Sendable
{
  private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  private let channel: any Channel
  private let inbox: DesktopLineInbox

  private init(channel: any Channel, inbox: DesktopLineInbox) {
    self.channel = channel
    self.inbox = inbox
  }

  public static func connect(port: Int) async throws -> DeepSeekHarnessDesktopSocket {
    guard (1...65_535).contains(port) else {
      throw AgentRuntimeError.invalidRequest("dsh.desktop.port")
    }
    let inbox = DesktopLineInbox()
    let channel = try await ClientBootstrap(group: group)
      .connectTimeout(.seconds(10))
      .channelInitializer { channel in
        channel.pipeline.addHandler(DesktopLineHandler(inbox: inbox))
      }
      .connect(host: "127.0.0.1", port: port).get()
    return Self(channel: channel, inbox: inbox)
  }

  public func send(_ data: Data) async throws {
    guard data.count <= 4 * 1_024 * 1_024, !data.contains(0x0A) else {
      throw AgentRuntimeError.oversizedFrame
    }
    var buffer = channel.allocator.buffer(capacity: data.count + 1)
    buffer.writeBytes(data)
    buffer.writeInteger(UInt8(0x0A))
    try await channel.writeAndFlush(buffer).get()
  }

  public func receive() async throws -> Data { try await inbox.next() }

  public func close() async {
    inbox.finish(AgentRuntimeError.processUnavailable)
    try? await channel.close().get()
  }
}

private final class DesktopLineInbox: @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [Data] = []
  private var waiter: CheckedContinuation<Data, any Error>?
  private var failure: (any Error)?

  func next() async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if !lines.isEmpty {
        let line = lines.removeFirst()
        lock.unlock()
        continuation.resume(returning: line)
      } else if let failure {
        lock.unlock()
        continuation.resume(throwing: failure)
      } else {
        guard waiter == nil else {
          lock.unlock()
          continuation.resume(throwing: AgentRuntimeError.invalidRequest("concurrent_receive"))
          return
        }
        waiter = continuation
        lock.unlock()
      }
    }
  }

  func push(_ line: Data) {
    lock.lock()
    guard failure == nil else {
      lock.unlock()
      return
    }
    if let waiter {
      self.waiter = nil
      lock.unlock()
      waiter.resume(returning: line)
    } else if lines.count < 256 {
      lines.append(line)
      lock.unlock()
    } else {
      lock.unlock()
      finish(AgentRuntimeError.oversizedFrame)
    }
  }

  func finish(_ error: any Error) {
    lock.lock()
    failure = error
    let waiter = self.waiter
    self.waiter = nil
    lock.unlock()
    waiter?.resume(throwing: error)
  }
}

// NIO confines this handler's buffer to the channel event loop.
private final class DesktopLineHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer
  private let inbox: DesktopLineInbox
  private var bytes = Data()

  init(inbox: DesktopLineInbox) { self.inbox = inbox }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    var buffer = unwrapInboundIn(data)
    if let chunk = buffer.readBytes(length: buffer.readableBytes) {
      bytes.append(contentsOf: chunk)
    }
    while let newline = bytes.firstIndex(of: 0x0A) {
      let line = Data(bytes[..<newline])
      bytes.removeSubrange(...newline)
      guard line.count <= 4 * 1_024 * 1_024 else {
        errorCaught(context: context, error: AgentRuntimeError.oversizedFrame)
        return
      }
      inbox.push(line)
    }
    if bytes.count > 4 * 1_024 * 1_024 {
      errorCaught(context: context, error: AgentRuntimeError.oversizedFrame)
    }
  }

  func channelInactive(context: ChannelHandlerContext) {
    inbox.finish(AgentRuntimeError.processUnavailable)
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    inbox.finish(error)
    context.close(promise: nil)
  }
}

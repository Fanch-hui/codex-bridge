import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

public actor ModelGatewayListener {
  private let configuration: ModelGatewayConfiguration
  private let authenticate: ModelGatewayAuthenticate
  private let handler: ModelGatewayRequestHandler
  private let admission: ModelGatewayAdmission
  private var server: (any Channel)?
  private var group: MultiThreadedEventLoopGroup?
  private var starting = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var draining = false
  private var finishing: Task<Void, Never>?

  public init(
    configuration: ModelGatewayConfiguration, authenticate: @escaping ModelGatewayAuthenticate,
    handler: @escaping ModelGatewayRequestHandler
  ) {
    self.configuration = configuration
    self.authenticate = authenticate
    self.handler = handler
    admission = ModelGatewayAdmission(
      maximumConnections: configuration.maximumConnections,
      maximumRequests: configuration.maximumRequests)
  }

  public func start() async throws -> ModelGatewayEndpoint {
    guard !draining, !starting else { throw ModelGatewayError.lifecycleTransitionInProgress }
    if let endpoint { return endpoint }
    starting = true
    defer { finishStarting() }
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    self.group = group
    var limits = NIOHTTPDecoderLimitConfiguration()
    limits.maxHeaderFieldSize = configuration.maximumHeaderBytes
    limits.maxHeaderListSize = configuration.maximumHeaderBytes
    let decoderLimits = limits
    let configuration = configuration
    let admission = admission
    let authenticate = authenticate
    let handler = handler
    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: 64)
      #if os(Windows)
        .serverChannelOption(
          ChannelOptions.socketOption(
            NIOBSDSocket.Option(rawValue: ~NIOBSDSocket.Option.so_reuseaddr.rawValue)), value: 1)
      #else
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      #endif
      .childChannelInitializer { channel in
        guard admission.register(channel) else { return channel.close() }
        return channel.pipeline.configureHTTPServerPipeline(
          withPipeliningAssistance: false, withErrorHandling: true,
          withDecoderLimitConfiguration: decoderLimits
        ).flatMap {
          channel.pipeline.addHandler(
            ModelGatewayHTTPHandler(
              configuration: configuration, admission: admission,
              authenticate: authenticate, handler: handler))
        }.flatMapError { error in
          admission.unregister(channel)
          return channel.close().flatMapThrowing { throw error }
        }
      }
      .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
      .childChannelOption(
        ChannelOptions.writeBufferWaterMark,
        value: ChannelOptions.Types.WriteBufferWaterMark(low: 32 * 1024, high: 64 * 1024))
    do {
      let channel = try await bootstrap.bind(host: "127.0.0.1", port: configuration.port).get()
      guard channel.localAddress?.ipAddress == "127.0.0.1",
        let port = channel.localAddress?.port
      else {
        try await channel.close().get()
        throw ModelGatewayError.unexpectedBindAddress
      }
      guard !draining else {
        try await channel.close().get()
        throw CancellationError()
      }
      server = channel
      return ModelGatewayEndpoint(host: "127.0.0.1", port: port)
    } catch {
      if !draining, self.group === group {
        self.group = nil
        try? await group.shutdownGracefully()
      }
      throw error
    }
  }

  /// Stops admitting requests while retaining in-flight responses.
  public func stopAccepting() async {
    if !draining {
      draining = true
      let idle = admission.stopAccepting()
      for channel in idle { try? await channel.close().get() }
    }
    if starting {
      await withCheckedContinuation { startWaiters.append($0) }
    }
    let channel = server
    server = nil
    try? await channel?.close().get()
  }

  /// Force closes client connections and requests cancellation; both modes await handler cleanup.
  public func shutdown(force: Bool = false) async {
    await stopAccepting()
    if force {
      for channel in admission.allChannels() { try? await channel.close().get() }
    }
    if let finishing {
      await finishing.value
      return
    }
    let group = group
    self.group = nil
    let admission = admission
    let finishing = Task {
      await admission.waitForDrain()
      for channel in admission.allChannels() { try? await channel.close().get() }
      try? await group?.shutdownGracefully()
      admission.reset()
    }
    self.finishing = finishing
    await finishing.value
    self.finishing = nil
    draining = false
  }

  public var endpoint: ModelGatewayEndpoint? {
    guard let address = server?.localAddress, address.ipAddress == "127.0.0.1",
      let port = address.port
    else { return nil }
    return ModelGatewayEndpoint(host: "127.0.0.1", port: port)
  }

  private func finishStarting() {
    starting = false
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }
}

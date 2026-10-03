#if os(Linux)
  import BridgeIPC
  import Foundation

  final class LinuxServiceConnection: @unchecked Sendable {
    private let channel: LinuxSocketChannel
    private let controller: BridgeServiceRequestController

    init(descriptor: Int32, composition: ServiceComposition) {
      let channel = LinuxSocketChannel(descriptor: descriptor)
      self.channel = channel
      controller = BridgeServiceRequestController(
        composition: composition, streamSink: LinuxServiceStreamSink(channel: channel)
      )
    }

    func start(completed: @escaping @Sendable (LinuxServiceConnection) -> Void) {
      let thread = Thread { [self] in
        defer {
          close()
          completed(self)
        }
        while let frame = try? channel.readFrame(), frame.kind == 0 {
          let response = dispatchSync(frame.payload)
          guard (try? channel.writeFrame(kind: 1, payload: response)) != nil else { return }
          if Self.shouldShutdown(request: frame.payload, response: response) {
            ServiceTerminationSignal.request()
            return
          }
        }
      }
      thread.name = "codex-bridge.socket-session"
      thread.start()
    }

    func close() {
      controller.stopStreaming()
      channel.close()
    }

    private func dispatchSync(_ payload: Data) -> Data {
      let semaphore = DispatchSemaphore(value: 0)
      nonisolated(unsafe) var response = Data()
      let controller = controller
      Task {
        response = await controller.dispatch(payload)
        semaphore.signal()
      }
      semaphore.wait()
      return response
    }

    private static func shouldShutdown(request: Data, response: Data) -> Bool {
      guard let request = try? BridgeServiceIPCCodec.decodeRequest(request),
        request.operation == .shutdownService,
        let response = try? BridgeServiceIPCCodec.response(response)
      else { return false }
      return response.error == nil
    }
  }

  private final class LinuxServiceStreamSink: ServiceStreamSink, @unchecked Sendable {
    private let channel: LinuxSocketChannel

    init(channel: LinuxSocketChannel) { self.channel = channel }

    func push(_ payload: Data) {
      try? channel.writeFrame(kind: 2, payload: payload)
    }
  }
#endif

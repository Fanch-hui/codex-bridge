#if os(Linux)
  import BridgeIPC
  import Foundation

  final class LinuxServiceConnection: @unchecked Sendable {
    private static let maximumConcurrentRequests = 128

    private let channel: LinuxSocketChannel
    private let controller: BridgeServiceRequestController
    private let stateLock = NSLock()
    private var closed = false
    private var inFlightTasks: [UInt64: Task<Void, Never>] = [:]

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
        while let frame = try? channel.readFrame() {
          switch frame.kind {
          case ServiceFrameKind.legacyRequest:
            let response = dispatchSync(frame.payload)
            let delivered =
              (try? channel.writeFrame(kind: ServiceFrameKind.legacyResponse, payload: response))
              != nil
            if Self.shouldShutdown(request: frame.payload, response: response) {
              ServiceTerminationSignal.request()
              return
            }
            guard delivered else { return }
          case ServiceFrameKind.multiplexedRequest:
            guard let (tag, body) = ServiceMultiplexedFrame.decode(frame.payload),
              body.count <= BridgeServiceIPC.maximumMessageBytes,
              dispatchMultiplexed(tag: tag, payload: body)
            else { return }
          default:
            return
          }
        }
      }
      thread.name = "codex-bridge.socket-session"
      thread.start()
    }

    func close() {
      let pending = stateLock.withLock { () -> [Task<Void, Never>] in
        guard !closed else { return [] }
        closed = true
        let tasks = Array(inFlightTasks.values)
        inFlightTasks.removeAll()
        return tasks
      }
      for task in pending { task.cancel() }
      controller.stopStreaming()
      channel.close()
    }

    private func dispatchMultiplexed(tag: UInt64, payload: Data) -> Bool {
      stateLock.lock()
      guard !closed, inFlightTasks[tag] == nil,
        inFlightTasks.count < Self.maximumConcurrentRequests
      else {
        stateLock.unlock()
        return false
      }
      let controller = controller
      let channel = channel
      let task = Task { [weak self] in
        defer { self?.finishTask(tag: tag) }
        let response = await controller.dispatch(payload)
        guard !Task.isCancelled else { return }
        let encoded = ServiceMultiplexedFrame.encode(tag: tag, payload: response)
        let delivered =
          (try? channel.writeFrame(kind: ServiceFrameKind.multiplexedResponse, payload: encoded))
          != nil
        if Self.shouldShutdown(request: payload, response: response) {
          ServiceTerminationSignal.request()
          self?.close()
          return
        }
        if !delivered { self?.close() }
      }
      inFlightTasks[tag] = task
      stateLock.unlock()
      return true
    }

    private func finishTask(tag: UInt64) {
      stateLock.lock()
      inFlightTasks.removeValue(forKey: tag)
      stateLock.unlock()
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
        request.operation == .shutdownService || request.operation == .shutdownServiceIfIdle,
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

#if os(macOS)
  import BridgeAgentCore
  import Foundation

  final class XPCStreamBridge: NSObject, CodexBridgeTaskStreamListener, @unchecked Sendable {
    private weak var transport: XPCServiceTransport?

    init(transport: XPCServiceTransport) {
      self.transport = transport
      super.init()
    }

    func push(_ payload: Data) {
      transport?.deliverStreamPush(payload)
    }
  }

  final class XPCServiceTransport: ServiceRequestTransport, @unchecked Sendable {
    private let connection: NSXPCConnection
    private let lock = NSLock()
    private var streamHandlerStore: (@Sendable (Data) -> Void)?
    private var invalidated = false

    var streamHandler: (@Sendable (Data) -> Void)? {
      get {
        lock.lock()
        defer { lock.unlock() }
        return streamHandlerStore
      }
      set {
        lock.lock()
        streamHandlerStore = newValue
        lock.unlock()
      }
    }

    init(machServiceName: String) {
      precondition(!machServiceName.isEmpty)
      let connection = NSXPCConnection(machServiceName: machServiceName)
      self.connection = connection
      configure(connection: connection)
      connection.resume()
    }

    init(endpoint: NSXPCListenerEndpoint) {
      let connection = NSXPCConnection(listenerEndpoint: endpoint)
      self.connection = connection
      configure(connection: connection)
      connection.resume()
    }

    deinit {
      connection.invalidate()
    }

    private func configure(connection: NSXPCConnection) {
      connection.remoteObjectInterface = NSXPCInterface(
        with: CodexBridgeServiceXPCProtocol.self
      )
      connection.exportedInterface = NSXPCInterface(
        with: CodexBridgeTaskStreamListener.self
      )
      connection.exportedObject = XPCStreamBridge(transport: self)
    }

    func deliverStreamPush(_ payload: Data) {
      streamHandler?(payload)
    }

    func perform(_ data: Data) async throws -> Data {
      try await withCheckedThrowingContinuation { continuation in
        let completion = XPCClientCompletion(continuation)
        let timeout = Self.responseTimeout(for: data)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
          if completion.resume(throwing: BridgeServiceClientError.unavailable) {
            self?.invalidate()
          }
        }
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            completion.resume(throwing: BridgeServiceClientError.unavailable)
          }) as? CodexBridgeServiceXPCProtocol
        else {
          completion.resume(throwing: BridgeServiceClientError.invalidRemoteProxy)
          return
        }
        proxy.perform(data) { response in
          completion.resume(returning: response)
        }
      }
    }

    static func responseTimeout(for data: Data) -> TimeInterval {
      guard let request = try? BridgeServiceIPCCodec.decodeRequest(data) else { return 120 }
      if request.operation == .status { return 3 }
      guard request.operation == .manageDeepSeekHarnessDesktop,
        let payload = try? BridgeServiceIPCCodec.payload(
          DeepSeekHarnessDesktopRequest.self, from: request),
        payload.action == .installConnector
      else { return 120 }
      // Include installation preflight and receipt delivery after the subprocess deadline.
      return TimeInterval(AgentSetupProcessLimits.maximumConnectorRunSeconds + 60)
    }

    func invalidate() {
      lock.lock()
      guard !invalidated else {
        lock.unlock()
        return
      }
      invalidated = true
      lock.unlock()
      connection.invalidate()
    }
  }

  private final class XPCClientCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?

    init(_ continuation: CheckedContinuation<Data, any Error>) {
      self.continuation = continuation
    }

    func resume(returning data: Data) {
      _ = resolve { $0.resume(returning: data) }
    }

    @discardableResult
    func resume(throwing error: any Error) -> Bool {
      resolve { $0.resume(throwing: error) }
    }

    private func resolve(
      _ body: (CheckedContinuation<Data, any Error>) -> Void
    ) -> Bool {
      lock.lock()
      let continuation = continuation
      self.continuation = nil
      lock.unlock()
      guard let continuation else { return false }
      body(continuation)
      return true
    }
  }
#endif

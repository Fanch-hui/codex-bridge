import BridgeACP
import Foundation

public typealias QoderJSONValue = ACPJSONValue

public enum QoderHostEvent: Sendable {
  case update(QoderJSONValue)
  case permission(ACPRequestID, QoderJSONValue)
  case userInput(ACPRequestID, QoderJSONValue)
}

public actor QoderSDKClient {
  public nonisolated let events: AsyncThrowingStream<QoderHostEvent, any Error>
  private let continuation: AsyncThrowingStream<QoderHostEvent, any Error>.Continuation
  private let broker: ACPRequestBroker
  private let transport: any ACPTransport
  private var reader: Task<Void, Never>?
  private var closing: Task<Void, Never>?
  private var closed = false
  private var lastSequence: Int64 = -1
  private var pendingPermissions = Set<ACPRequestID>()
  private var pendingUserInputs = Set<ACPRequestID>()
  private var requestCount = 0

  public init(transport: any ACPTransport, requestTimeout: Duration = .seconds(45)) {
    self.transport = transport
    broker = ACPRequestBroker(transport: transport, requestTimeout: requestTimeout)
    let stream = AsyncThrowingStream.makeStream(
      of: QoderHostEvent.self, throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(128))
    events = stream.stream
    continuation = stream.continuation
  }

  public func request(
    _ method: String, params: QoderJSONValue = .object([:]),
    timeout: Duration? = nil
  ) async throws -> QoderJSONValue {
    guard !closed, requestCount < 32 else { throw ACPError.transportClosed }
    start()
    requestCount += 1
    defer { requestCount -= 1 }
    do {
      return try await broker.request(method: method, params: params, timeout: timeout).value
    } catch {
      if case ACPError.remote = error { throw error }
      await shutdown()
      throw error
    }
  }

  public func resolve(_ id: ACPRequestID, result: QoderJSONValue) async throws {
    guard !closed, pendingPermissions.remove(id) != nil else { throw ACPError.invalidMessage }
    do { try await broker.send(ACPWireMessage(id: id, result: result)) } catch {
      await shutdown()
      throw error
    }
  }

  public func resolveUserInput(_ id: ACPRequestID, result: QoderJSONValue) async throws {
    guard !closed, pendingUserInputs.remove(id) != nil else { throw ACPError.invalidMessage }
    do { try await broker.send(ACPWireMessage(id: id, result: result)) } catch {
      await shutdown()
      throw error
    }
  }

  private func start() {
    guard reader == nil else { return }
    let source = transport.incoming
    reader = Task { [weak self] in
      do {
        for try await data in source {
          guard let self else { return }
          try await self.consume(data)
        }
        await self?.fail(ACPError.transportClosed)
      } catch { await self?.fail(error) }
    }
  }

  private func consume(_ data: Data) async throws {
    guard !closed else { return }
    let message = try JSONDecoder().decode(ACPWireMessage.self, from: data)
    switch try ACPMessageDispatcher.dispatch(message) {
    case .response(let id, let result, let error):
      guard
        broker.resolve(id: id, result: result, error: error, eventSequenceBarrier: lastSequence + 1)
      else { throw ACPError.invalidMessage }
    case .notification(let method, let params):
      guard method == "qoder/event", let params, let sequence = params["sequence"]?.intValue,
        sequence >= 0, Int64(sequence) == lastSequence + 1
      else { throw ACPError.invalidMessage }
      lastSequence = Int64(sequence)
      try yield(.update(params))
    case .serverRequest(let id, let method, let params):
      guard let params, pendingPermissions.count + pendingUserInputs.count < 32 else {
        throw ACPError.invalidMessage
      }
      if method == "qoder/permission", pendingPermissions.insert(id).inserted {
        try yield(.permission(id, params))
      } else if method == "qoder/question", pendingUserInputs.insert(id).inserted {
        try yield(.userInput(id, params))
      } else {
        throw ACPError.invalidMessage
      }
    }
  }

  private func yield(_ event: QoderHostEvent) throws {
    switch continuation.yield(event) {
    case .enqueued: return
    case .dropped, .terminated: throw ACPError.oversizedFrame
    @unknown default: throw ACPError.transportClosed
    }
  }

  private func fail(_ error: any Error) async {
    guard !closed else { return }
    broker.failAll(with: error)
    continuation.finish(throwing: error)
    await shutdown()
  }

  public func shutdown() async {
    if let closing {
      await closing.value
      return
    }
    closed = true
    reader?.cancel()
    pendingPermissions.removeAll()
    pendingUserInputs.removeAll()
    let task = Task { [broker] in await broker.close() }
    closing = task
    await task.value
    continuation.finish()
  }
}

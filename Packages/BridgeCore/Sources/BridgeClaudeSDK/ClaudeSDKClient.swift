import BridgeACP
import BridgeAgentCore
import Foundation

public typealias ClaudeJSONValue = ACPJSONValue

public enum ClaudeHostEvent: Sendable {
  case update(ClaudeJSONValue)
  case permission(ACPRequestID, ClaudeJSONValue)
  case userInput(ACPRequestID, ClaudeJSONValue)
  /// The host asks to take or give back the project write lease for one tool call.
  case workspaceWrite(ACPRequestID, ClaudeJSONValue)
}

public actor ClaudeSDKClient {
  private let eventDelivery: AgentEventStreamDelivery<ClaudeHostEvent>
  public nonisolated let events: AsyncThrowingStream<ClaudeHostEvent, any Error>
  private let continuation: AsyncThrowingStream<ClaudeHostEvent, any Error>.Continuation
  private let broker: ACPRequestBroker
  private let transport: any ACPTransport
  private var reader: Task<Void, Never>?
  private var closing: Task<Bool, Never>?
  private var closed = false
  private var lastSequence: Int64 = -1
  private var pendingPermissions: [ACPRequestID: Int] = [:]
  private var pendingUserInputs: [ACPRequestID: Int] = [:]
  private var pendingWrites = Set<ACPRequestID>()
  private var cancelledInteractionGeneration = -1
  private var requestCount = 0

  public init(transport: any ACPTransport, requestTimeout: Duration = .seconds(45)) {
    self.transport = transport
    let stream = AsyncThrowingStream.makeStream(
      of: ClaudeHostEvent.self, throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(128))
    events = stream.stream
    continuation = stream.continuation
    let delivery = AgentEventStreamDelivery(stream.continuation)
    eventDelivery = delivery
    broker = ACPRequestBroker(
      transport: transport, requestTimeout: requestTimeout,
      timeoutSuspended: { await delivery.hasPendingDelivery })
  }

  public func request(
    _ method: String, params: ClaudeJSONValue = .object([:]),
    timeout: Duration? = nil
  ) async throws -> ClaudeJSONValue {
    guard !closed, requestCount < 32 else { throw ACPError.transportClosed }
    start()
    requestCount += 1
    defer { requestCount -= 1 }
    do {
      return try await broker.request(
        method: method, params: params, timeout: timeout,
        suspendsTimeout: method != "claude/interrupt" && method != "claude/close"
      ).value
    } catch {
      if case ACPError.remote = error { throw error }
      await shutdown()
      throw error
    }
  }

  public func resolve(_ id: ACPRequestID, result: ClaudeJSONValue) async throws {
    guard !closed, pendingPermissions.removeValue(forKey: id) != nil else {
      throw ACPError.invalidMessage
    }
    do { try await broker.send(ACPWireMessage(id: id, result: result)) } catch {
      await shutdown()
      throw error
    }
  }

  public func resolveUserInput(_ id: ACPRequestID, result: ClaudeJSONValue) async throws {
    guard !closed, pendingUserInputs.removeValue(forKey: id) != nil else {
      throw ACPError.invalidMessage
    }
    do { try await broker.send(ACPWireMessage(id: id, result: result)) } catch {
      await shutdown()
      throw error
    }
  }

  public func resolveWorkspaceWrite(_ id: ACPRequestID, result: ClaudeJSONValue) async throws {
    guard !closed, pendingWrites.remove(id) != nil else { throw ACPError.invalidMessage }
    do { try await broker.send(ACPWireMessage(id: id, result: result)) } catch {
      await shutdown()
      throw error
    }
  }

  func cancelInteractions(through generation: Int) {
    cancelledInteractionGeneration = max(cancelledInteractionGeneration, generation)
    pendingPermissions = pendingPermissions.filter { $0.value > cancelledInteractionGeneration }
    pendingUserInputs = pendingUserInputs.filter { $0.value > cancelledInteractionGeneration }
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
      guard method == "claude/event", let params, let sequence = params["sequence"]?.intValue,
        sequence >= 0, Int64(sequence) == lastSequence + 1
      else { throw ACPError.invalidMessage }
      lastSequence = Int64(sequence)
      try await yield(.update(params))
    case .serverRequest(let id, let method, let params):
      if method == "claude/workspaceWrite" {
        try await workspaceWrite(id, params)
        return
      }
      guard ["claude/permission", "claude/question"].contains(method),
        let params, let generation = params["interactionGeneration"]?.intValue,
        generation >= 0, pendingCount < 32
      else {
        throw ACPError.invalidMessage
      }
      if generation <= cancelledInteractionGeneration { return }
      guard pendingPermissions[id] == nil, pendingUserInputs[id] == nil else {
        throw ACPError.invalidMessage
      }
      if method == "claude/permission" {
        pendingPermissions[id] = generation
        try await yield(.permission(id, params))
      } else if method == "claude/question" {
        pendingUserInputs[id] = generation
        try await yield(.userInput(id, params))
      } else {
        throw ACPError.invalidMessage
      }
    }
  }

  private var pendingCount: Int {
    pendingPermissions.count + pendingUserInputs.count + pendingWrites.count
  }

  /// Lease requests are never dropped as stale: the execution answers each one, so a release
  /// that races with an interrupt still reaches the gate.
  private func workspaceWrite(_ id: ACPRequestID, _ params: ClaudeJSONValue?) async throws {
    guard let params, pendingCount < 32, pendingWrites.insert(id).inserted else {
      throw ACPError.invalidMessage
    }
    try await yield(.workspaceWrite(id, params))
  }

  private func yield(_ event: ClaudeHostEvent) async throws {
    guard await eventDelivery.enqueue(event) else { throw ACPError.transportClosed }
  }

  private func fail(_ error: any Error) async {
    guard !closed else { return }
    broker.failAll(with: error)
    continuation.finish(throwing: error)
    await shutdown()
  }

  @discardableResult
  public func shutdown() async -> Bool {
    if let closing {
      return await closing.value
    }
    closed = true
    reader?.cancel()
    pendingPermissions.removeAll()
    pendingUserInputs.removeAll()
    pendingWrites.removeAll()
    let task = Task { [broker, transport] in
      let stopped: Bool
      if let process = transport as? ACPProcessTransport {
        stopped = await process.terminateAndConfirmProcessTree()
      } else {
        stopped = true
      }
      await broker.close()
      return stopped
    }
    closing = task
    let stopped = await task.value
    continuation.finish()
    return stopped
  }
}

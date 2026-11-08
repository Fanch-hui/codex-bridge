import BridgeACP
import BridgeAgentCore
import BridgeSecurity
import Foundation

actor EmbeddedDSHClient {
  typealias Callback = @Sendable (String, ACPJSONValue) async throws -> ACPJSONValue
  typealias EventHandler = @Sendable (EmbeddedDSHEvent) async -> Void
  typealias FailureHandler = @Sendable (EmbeddedDSHRuntimeError) async -> Void

  private struct Pending {
    let continuation: CheckedContinuation<ACPJSONValue, any Error>
    let timeoutTask: Task<Void, Never>
    var sent: Bool
    let cancelsExecution: Bool
  }

  private let transport: ACPProcessTransport
  private let callback: Callback
  private let eventHandler: EventHandler
  private let failureHandler: FailureHandler
  private let eventStream: AsyncStream<EmbeddedDSHEvent>
  private let eventContinuation: AsyncStream<EmbeddedDSHEvent>.Continuation
  private let eventDelivery: AgentEventStreamDelivery<EmbeddedDSHEvent>
  private var reader: Task<Void, Never>?
  private var eventPump: Task<Void, Never>?
  private var closing: Task<Bool, Never>?
  private var callbacks: [ACPRequestID: Task<Void, Never>] = [:]
  private var cancelledCallbacks = Set<ACPRequestID>()
  private var pending: [ACPRequestID: Pending] = [:]
  private var nextID: Int64 = 1
  private var closed = false

  init(
    transport: ACPProcessTransport,
    callback: @escaping Callback,
    eventHandler: @escaping EventHandler,
    failureHandler: @escaping FailureHandler
  ) {
    self.transport = transport
    self.callback = callback
    self.eventHandler = eventHandler
    self.failureHandler = failureHandler
    let stream = AsyncStream.makeStream(
      of: EmbeddedDSHEvent.self, bufferingPolicy: .bufferingOldest(64))
    eventStream = stream.stream
    eventContinuation = stream.continuation
    eventDelivery = AgentEventStreamDelivery(stream.continuation)
  }

  func start() {
    guard reader == nil, !closed else { return }
    let events = eventStream
    let eventHandler = eventHandler
    eventPump = Task {
      for await event in events { await eventHandler(event) }
    }
    let incoming = transport.incoming
    reader = Task { [weak self] in
      do {
        for try await data in incoming {
          guard let self else { return }
          try await self.consume(data)
        }
        await self?.fail(.transportClosed)
      } catch {
        await self?.fail(Self.mapError(error))
      }
    }
  }

  func request(action: String, payload: ACPJSONValue, timeout: Duration) async throws
    -> ACPJSONValue
  {
    guard !closed else { throw EmbeddedDSHRuntimeError.transportClosed }
    guard !action.isEmpty, action.utf8.count <= 256,
      !action.contains("\0"), timeout > .zero, nextID < Int64.max
    else { throw EmbeddedDSHRuntimeError.invalidConfiguration }
    guard pending.count < 128 else { throw EmbeddedDSHRuntimeError.busy }
    guard !Task.isCancelled else { throw CancellationError() }
    let id = ACPRequestID.integer(nextID)
    nextID += 1
    let message = ACPWireMessage(
      id: id, method: "bridge/call",
      params: .object(["action": .string(action), "payload": payload]))
    let frame = try Self.encode(message)
    let cancelsExecution = Self.cancelsExecution(action: action, payload: payload)

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !closed, !Task.isCancelled else {
          continuation.resume(
            throwing: Task.isCancelled
              ? CancellationError() : EmbeddedDSHRuntimeError.transportClosed)
          return
        }
        let timeoutTask = Task { [weak self] in
          do { try await Task.sleep(for: timeout) } catch { return }
          await self?.cancel(id, error: EmbeddedDSHRuntimeError.requestTimedOut)
        }
        pending[id] = Pending(
          continuation: continuation, timeoutTask: timeoutTask, sent: false,
          cancelsExecution: cancelsExecution)
        Task { [weak self] in
          await self?.sendRequest(id, frame: frame, cancelsExecution: cancelsExecution)
        }
      }
    } onCancel: {
      Task { await self.cancel(id, error: CancellationError()) }
    }
  }

  private func sendRequest(_ id: ACPRequestID, frame: Data, cancelsExecution: Bool) async {
    guard pending[id] != nil, !closed else { return }
    do {
      try await transport.send(frame)
      if var request = pending[id] {
        request.sent = true
        pending[id] = request
      } else if cancelsExecution {
        await sendCancellation(id)
      }
    } catch {
      await fail(Self.mapError(error))
    }
  }

  private func consume(_ data: Data) async throws {
    let message: ACPWireMessage
    do { message = try JSONDecoder().decode(ACPWireMessage.self, from: data) } catch {
      throw EmbeddedDSHRuntimeError.protocolViolation
    }
    switch try ACPMessageDispatcher.dispatch(message) {
    case .response(let id, let result, let error):
      guard let request = removePending(id) else { return }
      if let error {
        let message = OutboundContentSecurity.redactedSecrets(
          error.message, maximumUTF8Bytes: 4 * 1_024)
        request.continuation.resume(
          throwing: EmbeddedDSHRuntimeError.remote(code: error.code, message: message))
      } else if let result {
        request.continuation.resume(returning: result)
      } else {
        request.continuation.resume(throwing: EmbeddedDSHRuntimeError.protocolViolation)
      }
    case .notification(let method, let params):
      if method == "bridge/event", let params {
        let event = try EmbeddedDSHEvent(params: params)
        guard await eventDelivery.enqueue(event) else {
          throw EmbeddedDSHRuntimeError.transportClosed
        }
      } else if method == "$/cancelRequest", let id = Self.requestID(params?["id"]) {
        if let task = callbacks[id] {
          cancelledCallbacks.insert(id)
          task.cancel()
        }
      } else {
        throw EmbeddedDSHRuntimeError.protocolViolation
      }
    case .serverRequest(let id, let method, let params):
      guard method.hasPrefix("bridge/"), callbacks[id] == nil, callbacks.count < 128 else {
        throw EmbeddedDSHRuntimeError.protocolViolation
      }
      let callback = callback
      let task = Task { [weak self] in
        do {
          let value = try await callback(method, params ?? .object([:]))
          await self?.completeCallback(id, result: .success(value))
        } catch let error as EmbeddedDSHCallbackError {
          await self?.completeCallback(id, result: .failure(error))
        } catch {
          await self?.completeCallback(
            id, result: .failure(EmbeddedDSHCallbackError(code: -32603, message: "Bridge 请求失败。")))
        }
      }
      callbacks[id] = task
    }
  }

  private func completeCallback(
    _ id: ACPRequestID, result: Result<ACPJSONValue, EmbeddedDSHCallbackError>
  ) async {
    guard callbacks.removeValue(forKey: id) != nil else { return }
    let cancelled = cancelledCallbacks.remove(id) != nil
    guard !cancelled, !closed else { return }
    let message: ACPWireMessage
    switch result {
    case .success(let value):
      message = ACPWireMessage(id: id, result: value)
    case .failure(let error):
      message = ACPWireMessage(
        id: id, error: ACPWireError(code: error.code, message: error.message))
    }
    do { try await transport.send(Self.encode(message)) } catch { await fail(Self.mapError(error)) }
  }

  private func cancel(_ id: ACPRequestID, error: any Error) async {
    guard let request = removePending(id) else { return }
    request.continuation.resume(throwing: error)
    if request.sent, request.cancelsExecution { await sendCancellation(id) }
  }

  private static func cancelsExecution(action: String, payload: ACPJSONValue) -> Bool {
    let reads: Set<String> = [
      "status", "events", "pending.list", "session.list", "session.history",
      "session.content", "session.search", "session.receipt", "session.bindingSnapshot",
      "session.stopStatus",
      "models.list", "models.discover", "permissions.get", "settings.get", "context.get",
      "skills.list",
      "subagents.list", "subagents.history", "plugins.list", "plugins.installStatus",
      "configuration.status", "mcp.list", "client.graph", "client.bundle", "client.stream.poll",
    ]
    if reads.contains(action) { return true }
    if action == "client.rpc", let endpoint = payload["endpoint"]?.stringValue {
      return endpoint.hasSuffix("/list") || endpoint.hasSuffix("/get")
        || endpoint.hasSuffix("/describe")
        || ["session/page", "session/search", "session/projections", "fileReferences/list"]
          .contains(endpoint)
    }
    return false
  }

  private func sendCancellation(_ id: ACPRequestID) async {
    guard !closed else { return }
    let value: ACPJSONValue
    switch id {
    case .integer(let number): value = .integer(number)
    case .string(let string): value = .string(string)
    }
    let message = ACPWireMessage(method: "$/cancelRequest", params: .object(["id": value]))
    do { try await transport.send(Self.encode(message)) } catch { await fail(Self.mapError(error)) }
  }

  private func removePending(_ id: ACPRequestID) -> Pending? {
    guard let request = pending.removeValue(forKey: id) else { return nil }
    request.timeoutTask.cancel()
    return request
  }

  func close() async -> Bool {
    await close(withPendingError: .transportClosed)
  }

  func confirmedStopped() async -> Bool {
    guard closed else { return false }
    if let closing, await closing.value { return true }
    return await transport.terminateAndConfirmProcessTree()
  }

  private func close(withPendingError error: EmbeddedDSHRuntimeError) async -> Bool {
    if let closing { return await closing.value }
    guard !closed else { return await transport.terminateAndConfirmProcessTree() }
    closed = true
    reader?.cancel()
    finishPending(with: error)
    eventContinuation.finish()
    let callbackTasks = Array(callbacks.values)
    for task in callbackTasks { task.cancel() }
    callbacks.removeAll()
    cancelledCallbacks.removeAll()
    let transport = transport
    let eventPump = eventPump
    let task = Task {
      await transport.close()
      let stopped = await transport.terminateAndConfirmProcessTree()
      for callback in callbackTasks { await callback.value }
      await eventPump?.value
      return stopped
    }
    closing = task
    return await task.value
  }

  private func fail(_ error: EmbeddedDSHRuntimeError) async {
    guard !closed else { return }
    _ = await close(withPendingError: error)
    await failureHandler(error)
  }

  private func finishPending(with error: any Error) {
    let requests = Array(pending.values)
    pending.removeAll()
    for request in requests {
      request.timeoutTask.cancel()
      request.continuation.resume(throwing: error)
    }
  }

  private static func requestID(_ value: ACPJSONValue?) -> ACPRequestID? {
    switch value {
    case .integer(let number): .integer(number)
    case .string(let string): .string(string)
    default: nil
    }
  }

  private static func encode(_ message: ACPWireMessage) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    return try encoder.encode(message)
  }

  private static func mapError(_ error: any Error) -> EmbeddedDSHRuntimeError {
    switch error {
    case let error as EmbeddedDSHRuntimeError: error
    case ACPError.processExited(let code): .processExited(code)
    case ACPError.invalidMessage, ACPError.malformedResponse, ACPError.oversizedFrame:
      .protocolViolation
    default: .transportClosed
    }
  }
}

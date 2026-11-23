import BridgeACP
import BridgeSecurity
import Foundation

/// The community provider host's wire format is JSONL, not an ACP JSON-RPC envelope.
public actor ProviderHostClient {
  public typealias SecretHandler = @Sendable (ACPJSONValue) async throws -> ACPJSONValue
  public typealias StreamHandler = @Sendable (ProviderResponseEvent) async throws -> Void

  struct Pending {
    let continuation: CheckedContinuation<ACPJSONValue, any Error>
    let deadline: Task<Void, Never>
    let stream: StreamHandler?
    let isAbort: Bool
    var delivery: ProviderStreamDelivery?
    var sent = false
    var cancelling = false
    var receivedHead = false
  }

  let transport: any ACPTransport
  let secretHandler: SecretHandler
  var pending: [Int64: Pending] = [:]
  var callbacks: [String: Task<Void, Never>] = [:]
  var nextID: Int64 = 1
  var reader: Task<Void, Never>?
  var closed = false
  var closing: Task<Bool, Never>?

  public var isClosed: Bool { closed }

  public init(transport: any ACPTransport, secretHandler: @escaping SecretHandler) {
    self.transport = transport
    self.secretHandler = secretHandler
  }

  public static func launch(
    configuration: ACPProcessTransportConfiguration, parameters: ACPJSONValue,
    secretHandler: @escaping SecretHandler
  ) async throws -> ProviderHostClient {
    try Task.checkCancellation()
    let transport = try ACPProcessTransport.launch(configuration: configuration)
    let client = ProviderHostClient(transport: transport, secretHandler: secretHandler)
    await client.start()
    do {
      _ = try await client.request(method: "init", params: parameters)
      try Task.checkCancellation()
      return client
    } catch {
      guard await client.close() else { throw ProviderRuntimeError.processTreeStillRunning }
      throw error
    }
  }

  public func start() {
    guard reader == nil, !closed else { return }
    let incoming = transport.incoming
    reader = Task { [weak self] in
      do {
        for try await frame in incoming {
          guard let self else { return }
          try await self.consume(frame)
        }
        _ = await self?.close()
      } catch {
        _ = await self?.close(error: error)
      }
    }
  }

  public func request(
    method: String, params: ACPJSONValue = .object([:]), timeout: Duration = .seconds(60),
    stream: StreamHandler? = nil
  ) async throws -> ACPJSONValue {
    guard !closed else { throw ProviderRuntimeError.closed }
    guard timeout > .zero, nextID < Int64.max, !method.isEmpty,
      (method == "fetch") == (stream != nil)
    else { throw ProviderRuntimeError.invalidMessage }
    guard pending.count < 64 else { throw ProviderRuntimeError.busy }
    try Task.checkCancellation()
    let id = nextID
    nextID += 1
    var arguments = params
    if method == "fetch" {
      guard var fields = params.objectValue else { throw ProviderRuntimeError.invalidMessage }
      fields["window"] = .integer(512 * 1024)
      arguments = .object(fields)
    }
    let frame = try ACPJSONValue.object([
      "id": .integer(id), "method": .string(method), "params": arguments,
    ]).encodedData()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !closed, !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        let deadline = Task { [weak self] in
          do { try await Task.sleep(for: timeout) } catch { return }
          await self?.cancel(id, error: ProviderRuntimeError.timedOut)
        }
        pending[id] = Pending(
          continuation: continuation, deadline: deadline, stream: stream, isAbort: method == "abort"
        )
        if let stream { pending[id]?.delivery = makeDelivery(id: id, handler: stream) }
        Task { [weak self] in await self?.sendRequest(id, frame: frame) }
      }
    } onCancel: {
      Task { await self.cancel(id, error: CancellationError()) }
    }
  }

  func sendRequest(_ id: Int64, frame: Data) async {
    guard pending[id] != nil, !closed else { return }
    // Mark before suspension so cancellation cannot mistake an in-flight write for an unsent one.
    pending[id]?.sent = true
    do { try await transport.send(frame) } catch { _ = await close(error: error) }
  }

  func send(_ value: ACPJSONValue) async throws {
    try await transport.send(value.encodedData())
  }

  func finish(_ id: Int64, result: Result<ACPJSONValue, any Error>) {
    guard let item = pending.removeValue(forKey: id) else { return }
    item.deadline.cancel()
    item.delivery?.continuation.finish()
    item.continuation.resume(with: result)
  }

  func cancel(_ id: Int64, error: any Error) async {
    guard let item = pending[id], !item.cancelling else { return }
    pending[id]?.cancelling = true
    item.deadline.cancel()
    item.delivery?.task.cancel()
    item.delivery?.continuation.finish()
    await finishCancellation(id, item: item, error: error)
  }

  func finishCancellation(_ id: Int64, item: Pending, error: any Error) async {
    guard item.sent else {
      finish(id, result: .failure(error))
      return
    }
    guard !item.isAbort else {
      _ = await close(error: error)
      return
    }
    do {
      // Acknowledgement comes after the host has unwound the operation, not on abort receipt.
      _ = try await request(
        method: "abort", params: .object(["id": .integer(id)]), timeout: .seconds(5))
      finish(id, result: .failure(error))
    } catch {
      _ = await close(error: error)
    }
  }

  @discardableResult
  public func close() async -> Bool {
    await close(error: ProviderRuntimeError.closed)
  }

  func close(error: any Error) async -> Bool {
    if let closing { return await closing.value }
    closed = true
    reader?.cancel()
    for item in pending.values {
      item.delivery?.task.cancel()
      item.delivery?.continuation.finish()
    }
    let callbackTasks = Array(callbacks.values)
    callbacks.removeAll()
    for task in callbackTasks { task.cancel() }
    let transport = transport
    let close = Task {
      await transport.close()
      let stopped: Bool
      if let process = transport as? ACPProcessTransport {
        stopped = await process.terminateAndConfirmProcessTree()
      } else {
        stopped = true
      }
      for task in callbackTasks { await task.value }
      return stopped
    }
    closing = close
    let stopped = await close.value
    for id in Array(pending.keys) {
      finish(
        id, result: .failure(stopped ? error : ProviderRuntimeError.processTreeStillRunning))
    }
    return stopped
  }
}

public enum ProviderResponseEvent: Sendable, Equatable {
  case head(status: Int, headers: [String: String])
  case chunk(Data)
}

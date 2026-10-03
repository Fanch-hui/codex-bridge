import Foundation

public actor PiRPCClient {
  public nonisolated let events: AsyncThrowingStream<PiRPCEvent, any Error>
  private let continuation: AsyncThrowingStream<PiRPCEvent, any Error>.Continuation
  private let transport: any PiRPCTransport
  private let requestTimeout: Duration
  private let maximumRecordBytes: Int
  private var reader: Task<Void, Never>?
  private var writeTail: Task<Void, any Error>?
  private var pending: [String: Pending] = [:]
  private var closed = false
  private var sequence: Int64 = 0
  private var statusRecords: [String: String] = [:]

  private struct Pending {
    let command: String
    let continuation: CheckedContinuation<PiRPCReply, any Error>
    let timeout: Task<Void, Never>
  }

  public init(
    transport: any PiRPCTransport,
    requestTimeout: Duration = .seconds(30),
    maximumRecordBytes: Int = 16 * 1_024 * 1_024,
    eventBufferLimit: Int = 64
  ) {
    self.transport = transport
    self.requestTimeout = requestTimeout
    self.maximumRecordBytes = max(1, maximumRecordBytes)
    let stream = AsyncThrowingStream.makeStream(
      of: PiRPCEvent.self, throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(max(1, eventBufferLimit)))
    events = stream.stream
    continuation = stream.continuation
  }

  public var eventSequence: Int64 { sequence }
  public func status(_ key: String) -> String? { statusRecords[key] }

  public func start() {
    guard reader == nil, !closed else { return }
    let source = transport.incoming
    reader = Task { [weak self] in
      do {
        for try await record in source {
          guard let self else { return }
          await self.receive(record)
        }
        await self?.finish(PiRPCError.closed)
      } catch {
        await self?.finish(error)
      }
    }
  }

  public func request(
    _ command: String,
    fields: [String: PiJSONValue] = [:],
    timeout: Duration? = nil
  ) async throws -> PiRPCReply {
    try Task.checkCancellation()
    guard !closed else { throw PiRPCError.closed }
    guard !command.isEmpty, command.utf8.count <= 128,
      fields["type"] == nil, fields["id"] == nil, pending.count < 64
    else { throw PiRPCError.invalidArgument("command") }
    let id = UUID().uuidString.lowercased()
    var record = fields
    record["type"] = .string(command)
    record["id"] = .string(id)
    let bytes = try PiJSONValue.object(record).encoded()
    guard bytes.count <= maximumRecordBytes else { throw PiRPCError.oversizedFrame }
    start()
    let duration = timeout ?? requestTimeout
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { reply in
        guard !Task.isCancelled else {
          reply.resume(throwing: CancellationError())
          return
        }
        let timer = Task { [weak self] in
          do { try await Task.sleep(for: duration) } catch { return }
          await self?.requestExpired(id)
        }
        pending[id] = Pending(command: command, continuation: reply, timeout: timer)
        let write = enqueue(bytes)
        Task { [weak self] in
          do { try await write.value } catch { await self?.finish(error) }
        }
      }
    } onCancel: {
      Task { await self.cancelRequest(id) }
    }
  }

  public func answerUI(id: String, fields: [String: PiJSONValue]) async throws {
    guard !closed else { throw PiRPCError.closed }
    guard !id.isEmpty, id.utf8.count <= 256,
      Set(fields.keys).isSubset(of: ["value", "confirmed", "cancelled"]),
      fields.count == 1,
      fields["value"]?.stringValue != nil || fields["confirmed"]?.boolValue != nil
        || fields["cancelled"]?.boolValue == true
    else { throw PiRPCError.invalidArgument("extension_ui_response") }
    var value = fields
    value["type"] = .string("extension_ui_response")
    value["id"] = .string(id)
    let bytes = try PiJSONValue.object(value).encoded()
    guard bytes.count <= maximumRecordBytes else { throw PiRPCError.oversizedFrame }
    let write = enqueue(bytes)
    do { try await write.value } catch {
      await finish(error)
      throw error
    }
  }

  private func enqueue(_ bytes: Data) -> Task<Void, any Error> {
    let previous = writeTail
    let write = Task { [transport] in
      try await previous?.value
      try Task.checkCancellation()
      try await transport.send(bytes)
    }
    writeTail = write
    return write
  }

  public func shutdown() async { await finish(nil) }

  private func receive(_ bytes: Data) async {
    guard !closed else { return }
    do {
      guard !bytes.isEmpty, bytes.count <= maximumRecordBytes,
        let record = try JSONDecoder().decode(PiJSONValue.self, from: bytes).objectValue,
        let type = record["type"]?.stringValue, !type.isEmpty
      else { throw PiRPCError.invalidRecord }
      if type == "response" {
        try resolve(record)
        return
      }
      cacheStatus(record)
      guard sequence < Int64.max else { throw PiRPCError.invalidRecord }
      let event = PiRPCEvent(sequence: sequence, value: .object(record))
      sequence += 1
      if case .dropped = continuation.yield(event) { throw PiRPCError.oversizedFrame }
    } catch {
      await finish(error)
    }
  }

  private func resolve(_ record: [String: PiJSONValue]) throws {
    guard let id = record["id"]?.stringValue,
      let request = pending[id],
      record["command"]?.stringValue == request.command,
      let success = record["success"]?.boolValue
    else { throw PiRPCError.responseMismatch }
    pending.removeValue(forKey: id)
    request.timeout.cancel()
    if success {
      request.continuation.resume(
        returning: PiRPCReply(data: record["data"], eventSequenceBarrier: sequence))
    } else {
      let message = record["error"]?.stringValue ?? "Pi rejected the command."
      request.continuation.resume(
        throwing: PiRPCError.remote(command: request.command, message: String(message.prefix(512))))
    }
  }

  private func cacheStatus(_ record: [String: PiJSONValue]) {
    guard record["type"]?.stringValue == "extension_ui_request",
      record["method"]?.stringValue == "setStatus",
      let key = record["statusKey"]?.stringValue, key.utf8.count <= 128
    else { return }
    let value = record["statusText"]?.stringValue
    guard value.map({ $0.utf8.count <= 16 * 1_024 }) ?? true else { return }
    if statusRecords[key] != nil || statusRecords.count < 32 { statusRecords[key] = value }
  }

  private func requestExpired(_ id: String) async {
    guard pending[id] != nil else { return }
    await finish(PiRPCError.timedOut)
  }

  private func cancelRequest(_ id: String) async {
    guard pending[id] != nil else { return }
    await finish(CancellationError())
  }

  private func finish(_ error: (any Error)?) async {
    guard !closed else { return }
    closed = true
    writeTail?.cancel()
    writeTail = nil
    reader?.cancel()
    reader = nil
    let requests = pending.values
    pending.removeAll()
    for request in requests {
      request.timeout.cancel()
      request.continuation.resume(throwing: error ?? PiRPCError.closed)
    }
    statusRecords.removeAll()
    if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    await transport.close()
  }
}

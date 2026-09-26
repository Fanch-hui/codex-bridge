import Foundation

@testable import BridgePiRPC

actor PiRPCFixture: PiRPCTransport {
  nonisolated let incoming: AsyncThrowingStream<Data, any Error>
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private(set) var records: [PiJSONValue] = []
  private(set) var closeCount = 0
  private(set) var concurrentWrites = 0
  private var writes = 0
  let writeDelay: Duration

  init(writeDelay: Duration = .zero) {
    self.writeDelay = writeDelay
    let values = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
    incoming = values.stream
    continuation = values.continuation
  }

  func send(_ record: Data) async throws {
    guard closeCount == 0 else { throw PiRPCError.closed }
    writes += 1
    concurrentWrites = max(concurrentWrites, writes)
    defer { writes -= 1 }
    if writeDelay > .zero { try await Task.sleep(for: writeDelay) }
    records.append(try JSONDecoder().decode(PiJSONValue.self, from: record))
  }

  func close() async {
    closeCount += 1
    continuation.finish()
  }

  func emit(_ record: PiJSONValue) throws { continuation.yield(try record.encoded()) }
  func emitRaw(_ bytes: Data) { continuation.yield(bytes) }

  func reply(
    to index: Int, data: PiJSONValue? = nil, command: String? = nil,
    success: Bool = true, error: String? = nil
  ) throws {
    let request = records[index]
    var reply: [String: PiJSONValue] = [
      "id": request["id"]!, "type": .string("response"),
      "command": command.map(PiJSONValue.string) ?? request["type"]!,
      "success": .bool(success),
    ]
    reply["data"] = data
    reply["error"] = error.map(PiJSONValue.string)
    try emit(.object(reply))
  }

  func waitForRecords(_ count: Int) async throws -> [PiJSONValue] {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while records.count < count {
      guard ContinuousClock.now < deadline else { throw PiRPCError.timedOut }
      try await Task.sleep(for: .milliseconds(2))
    }
    return records
  }
}

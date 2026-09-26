import Foundation
import Testing

@testable import BridgePiRPC

struct PiRPCClientTests {
  @Test func correlatesOutOfOrderResponsesAndEventBarrier() async throws {
    let transport = PiRPCFixture()
    let client = PiRPCClient(transport: transport)
    let first = Task { try await client.request("get_state") }
    _ = try await transport.waitForRecords(1)
    let second = Task { try await client.request("get_commands") }
    _ = try await transport.waitForRecords(2)
    try await transport.emit(.object(["type": .string("agent_start")]))
    try await transport.reply(to: 1, data: .string("second"))
    try await transport.reply(to: 0, data: .string("first"))
    let firstReply = try await first.value
    let secondReply = try await second.value
    #expect(firstReply.data == .string("first"))
    #expect(secondReply.data == .string("second"))
    #expect(firstReply.eventSequenceBarrier == 1)
    #expect(secondReply.eventSequenceBarrier == 1)
    await client.shutdown()
  }

  @Test func mismatchedResponseClosesAllRequests() async throws {
    let transport = PiRPCFixture()
    let client = PiRPCClient(transport: transport)
    let request = Task { try await client.request("get_state") }
    _ = try await transport.waitForRecords(1)
    try await transport.reply(to: 0, command: "set_model")
    await #expect(throws: PiRPCError.responseMismatch) { try await request.value }
    await client.shutdown()
    #expect(await transport.closeCount == 1)
  }

  @Test func malformedRecordFailsPendingRequest() async throws {
    let transport = PiRPCFixture()
    let client = PiRPCClient(transport: transport)
    let request = Task { try await client.request("get_state") }
    _ = try await transport.waitForRecords(1)
    await transport.emitRaw(Data("not-json".utf8))
    await #expect(throws: (any Error).self) { try await request.value }
    await client.shutdown()
  }

  @Test func timeoutClosesChannel() async throws {
    let transport = PiRPCFixture()
    let client = PiRPCClient(transport: transport, requestTimeout: .milliseconds(30))
    await #expect(throws: PiRPCError.timedOut) { try await client.request("get_state") }
    await #expect(throws: PiRPCError.closed) { try await client.request("get_state") }
    await client.shutdown()
  }

  @Test func cancellationFinishesPendingRequest() async throws {
    let transport = PiRPCFixture()
    let client = PiRPCClient(transport: transport)
    let request = Task { try await client.request("get_state") }
    _ = try await transport.waitForRecords(1)
    request.cancel()
    await #expect(throws: CancellationError.self) { try await request.value }
    await client.shutdown()
    #expect(await transport.closeCount == 1)
  }

  @Test func remoteFailureDoesNotCloseHealthyChannel() async throws {
    let transport = PiRPCFixture()
    let client = PiRPCClient(transport: transport)
    let first = Task { try await client.request("set_model") }
    _ = try await transport.waitForRecords(1)
    try await transport.reply(to: 0, success: false, error: "unavailable")
    await #expect(throws: PiRPCError.remote(command: "set_model", message: "unavailable")) {
      try await first.value
    }
    let second = Task { try await client.request("get_state") }
    _ = try await transport.waitForRecords(2)
    try await transport.reply(to: 1, data: .string("ready"))
    #expect(try await second.value.data == .string("ready"))
    await client.shutdown()
  }

  @Test func eventOverflowFailsClosed() async throws {
    let transport = PiRPCFixture()
    let client = PiRPCClient(transport: transport, eventBufferLimit: 1)
    let request = Task { try await client.request("get_state") }
    _ = try await transport.waitForRecords(1)
    try await transport.emit(.object(["type": .string("agent_start")]))
    try await transport.emit(.object(["type": .string("agent_end")]))
    await #expect(throws: PiRPCError.oversizedFrame) { try await request.value }
    await client.shutdown()
  }

  @Test func oversizedOutgoingRecordIsRejectedBeforeWrite() async throws {
    let transport = PiRPCFixture()
    let client = PiRPCClient(transport: transport, maximumRecordBytes: 128)
    await #expect(throws: PiRPCError.oversizedFrame) {
      try await client.request(
        "prompt", fields: ["message": .string(String(repeating: "x", count: 256))])
    }
    #expect(await transport.records.isEmpty)
    await client.shutdown()
  }

  @Test func commandFieldsCannotReplaceProtocolIdentity() async throws {
    let transport = PiRPCFixture()
    let client = PiRPCClient(transport: transport)
    await #expect(throws: PiRPCError.invalidArgument("command")) {
      try await client.request("prompt", fields: ["type": .string("abort")])
    }
    #expect(await transport.records.isEmpty)
    await client.shutdown()
  }

  @Test func uiResponseRetainsWireIDAndValidatesType() async throws {
    let transport = PiRPCFixture()
    let client = PiRPCClient(transport: transport)
    try await client.answerUI(id: "dialog-17", fields: ["value": .string("allow_once")])
    let records = try await transport.waitForRecords(1)
    #expect(records[0]["id"] == .string("dialog-17"))
    #expect(records[0]["type"] == .string("extension_ui_response"))
    await #expect(throws: PiRPCError.invalidArgument("extension_ui_response")) {
      try await client.answerUI(id: "dialog-17", fields: ["confirmed": .string("true")])
    }
    await #expect(throws: PiRPCError.invalidArgument("extension_ui_response")) {
      try await client.answerUI(id: "dialog-17", fields: ["cancelled": .bool(false)])
    }
    #expect(await transport.records.count == 1)
    await client.shutdown()
  }

  @Test func writesAreSerializedAcrossCommandsAndUI() async throws {
    let transport = PiRPCFixture(writeDelay: .milliseconds(10))
    let client = PiRPCClient(transport: transport)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<12 {
        group.addTask {
          try await client.answerUI(id: "dialog-\(index)", fields: ["cancelled": .bool(true)])
        }
      }
      try await group.waitForAll()
    }
    #expect(await transport.records.count == 12)
    #expect(await transport.concurrentWrites == 1)
    await client.shutdown()
  }

  @Test func startupStatusIsAvailableBeforeReplyReturns() async throws {
    let transport = PiRPCFixture()
    let client = PiRPCClient(transport: transport)
    let request = Task { try await client.request("get_state") }
    _ = try await transport.waitForRecords(1)
    try await transport.emit(
      .object([
        "type": .string("extension_ui_request"),
        "method": .string("setStatus"), "statusKey": .string("codex-bridge.pi"),
        "statusText": .string("ready"),
      ]))
    try await transport.reply(to: 0)
    _ = try await request.value
    #expect(await client.status("codex-bridge.pi") == "ready")
    await client.shutdown()
  }

  @Test func unicodeSeparatorsRoundTripAsJSONContent() throws {
    let value = PiJSONValue.object(["text": .string("甲\u{2028}乙\u{2029}丙\n丁")])
    let bytes = try value.encoded()
    #expect(!bytes.contains(0x0A))
    #expect(try JSONDecoder().decode(PiJSONValue.self, from: bytes) == value)
  }
}

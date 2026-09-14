import BridgeACP
import BridgeAgentCore
import BridgeDomain
import XCTest

@testable import BridgeDeepSeekHarnessACP

final class DeepSeekHarnessACPModernUpdatesTests: XCTestCase {
  func testLatestStandardUpdateSequenceDoesNotDisconnectTheClient() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id))
      case "session/new":
        try await transport.emit(deepSeekSessionResult(id: id, sessionID: "modern-session"))
      case "session/prompt":
        try await transport.emit(
          latestDeepSeekSessionUpdate(
            sessionID: "modern-session",
            update: [
              "sessionUpdate": .string("agent_thought_chunk"),
              "content": .object([
                "type": .string("text"),
                "text": .string("thinking"),
              ]),
            ]
          )
        )
        try await transport.emit(
          deepSeekMessageChunk(sessionID: "modern-session", text: "answer")
        )
        try await transport.emit(
          latestDeepSeekSessionUpdate(
            sessionID: "modern-session",
            update: [
              "sessionUpdate": .string("config_option_update"),
              "configOptions": .array([]),
            ]
          )
        )
        try await transport.emit(
          latestDeepSeekSessionUpdate(
            sessionID: "modern-session",
            update: [
              "sessionUpdate": .string("usage_update"),
              "used": .integer(12),
              "size": .integer(100),
            ]
          )
        )
        try await transport.emit(deepSeekPromptResult(id: id))
      default:
        break
      }
    }
    let client = DeepSeekHarnessACPClient(
      transport: transport,
      clientInfo: .init(name: "tests", title: "Tests", version: "1")
    )
    addTeardownBlock { await client.shutdown() }

    _ = try await client.initialize()
    let session = try await client.newSession(cwd: "/tmp")
    let prompt = Task { try await client.prompt(sessionID: session.id, text: "hello") }
    var iterator = client.events.makeAsyncIterator()
    var events: [DeepSeekHarnessACPClientEventEnvelope] = []
    while events.count < 4, let event = await iterator.next() {
      events.append(event)
    }

    let result = try await prompt.value
    XCTAssertEqual(result.stopReason, "end_turn")
    XCTAssertEqual(result.eventSequenceBarrier, 4)
    XCTAssertEqual(events.map(\.sequence), [0, 1, 2, 3])
    XCTAssertTrue(
      events.contains { event in
        if case .reasoningDelta("modern-session", "thinking") = event.event { return true }
        return false
      })
    XCTAssertTrue(
      events.contains { event in
        if case .textDelta("modern-session", "answer") = event.event { return true }
        return false
      })
    XCTAssertTrue(
      events.contains { event in
        if case .configurationUpdated("modern-session") = event.event { return true }
        return false
      })
    XCTAssertTrue(
      events.contains { event in
        if case .usageUpdated("modern-session", 12, 100) = event.event { return true }
        return false
      })
    let terminalFailure = await client.terminalFailure()
    XCTAssertNil(terminalFailure)
  }

  func testReasoningCommitsBeforeAnswerAndStartsANewBlock() async throws {
    let binding = try AgentBinding(
      providerID: .deepSeekHarness, installationID: .init(rawValue: "installation"),
      providerSessionID: "session", providerRunID: "run"
    )
    let normalizer = DeepSeekHarnessACPEventNormalizer(
      taskID: .init(rawValue: "task"), binding: binding)
    _ = try await normalizer.normalizeForExecution(
      .init(
        sequence: 0, event: .reasoningDelta(sessionID: "session", text: "plan")
      ))
    let events = try await normalizer.normalizeForExecution(
      .init(
        sequence: 1, event: .textDelta(sessionID: "session", text: "answer")
      ))
    guard case .content(let reasoning) = events.first?.event else {
      return XCTFail("Expected reasoning commit")
    }
    XCTAssertEqual(reasoning.kind, .reasoning)
    XCTAssertTrue(reasoning.isFinal)
    XCTAssertTrue(reasoning.authoritative)
    let next = try await normalizer.normalize(
      .init(
        sequence: 2, event: .reasoningDelta(sessionID: "session", text: "next")
      ))
    guard case .content(let update) = next?.event else { return XCTFail("Expected next reasoning") }
    XCTAssertEqual(update.key, "reasoning:assistant:1")
    XCTAssertEqual(update.baseContentLength, 0)
  }

  func testLatestThoughtAndUsageUpdatesMapToAgentEvents() async throws {
    let binding = try AgentBinding(
      providerID: .deepSeekHarness,
      installationID: .init(rawValue: "installation"),
      providerSessionID: "session",
      providerRunID: "run"
    )
    let normalizer = DeepSeekHarnessACPEventNormalizer(
      taskID: .init(rawValue: "task"),
      binding: binding
    )

    let reasoning = try await normalizer.normalize(
      .init(sequence: 0, event: .reasoningDelta(sessionID: "session", text: "plan"))
    )
    guard case .content(let reasoningUpdate) = reasoning?.event else {
      return XCTFail("Expected reasoning content")
    }
    XCTAssertEqual(reasoningUpdate.kind, .reasoning)
    XCTAssertEqual(reasoningUpdate.key, "reasoning:assistant")
    XCTAssertEqual(reasoningUpdate.baseContentLength, 0)

    let usage = try await normalizer.normalize(
      .init(
        sequence: 1,
        event: .usageUpdated(sessionID: "session", usedTokens: 12, contextSize: 100)
      )
    )
    guard case .usage(let usageUpdate) = usage?.event else {
      return XCTFail("Expected usage update")
    }
    XCTAssertEqual(usageUpdate.usedTokens, 12)
    XCTAssertEqual(usageUpdate.contextSize, 100)

    let configuration = try await normalizer.normalize(
      .init(sequence: 2, event: .configurationUpdated(sessionID: "session"))
    )
    XCTAssertNil(configuration)
  }
}

private func latestDeepSeekSessionUpdate(
  sessionID: String,
  update: [String: ACPJSONValue]
) -> ACPWireMessage {
  ACPWireMessage(
    method: "session/update",
    params: .object([
      "sessionId": .string(sessionID),
      "update": .object(update),
    ])
  )
}

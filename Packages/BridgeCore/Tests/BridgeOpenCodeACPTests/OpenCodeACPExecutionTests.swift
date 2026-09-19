import BridgeAgentCore
import BridgeDomain
import Foundation
import XCTest

@testable import BridgeOpenCodeACP

final class OpenCodeACPExecutionTests: XCTestCase {
  func testUnknownStopReasonFailsWithoutCompletion() async throws {
    let events = try await run(scenario: .unknownStopReason)

    assertFailure(
      events,
      code: "opencode_unknown_stop_reason",
      message: "OpenCode returned an unsupported stop reason."
    )
  }

  func testMaxTokensStopReasonFailsWithoutCompletion() async throws {
    let events = try await run(scenario: .maxTokens)

    assertFailure(
      events,
      code: "opencode_incomplete",
      message: "OpenCode stopped before producing a complete answer."
    )
  }

  func testUnfinishedToolFailsEvenWithPartialAssistantText() async throws {
    let events = try await run(scenario: .unfinishedTool)

    assertFailure(
      events,
      code: "opencode_unfinished_tool",
      message: "OpenCode ended the turn with an unfinished tool call."
    )
  }

  func testReasoningOnlyTurnFailsWithoutCompletion() async throws {
    let events = try await run(scenario: .reasoningOnly)

    assertFailure(
      events,
      code: "opencode_empty_response",
      message: "OpenCode ended the turn without a committed assistant message."
    )
  }

  func testNormalEndTurnWithSettledToolAndAssistantTextCompletes() async throws {
    let events = try await run(scenario: .normal)

    XCTAssertFalse(
      events.contains { envelope in
        if case .failed = envelope.event { return true }
        return false
      })
    XCTAssertTrue(
      events.contains { envelope in
        guard case .tool(let update) = envelope.event else { return false }
        return update.status == .completed
      })
    XCTAssertTrue(
      events.contains { envelope in
        guard case .content(let update) = envelope.event else { return false }
        return update.isFinal
          && update.authoritative
          && update.role == .assistant
          && update.kind == .message
          && update.content == "Final answer"
      })
    XCTAssertTrue(
      events.contains { envelope in
        guard case .completed(let summary, let stopReason) = envelope.event else { return false }
        return summary == "Final answer" && stopReason == "end_turn"
      })
  }

  func testRemoteFailurePreservesSafeProviderDetail() async throws {
    let events = try await run(scenario: .providerError)
    let summaries = events.compactMap { envelope -> String? in
      guard case .failed(_, let summary) = envelope.event else { return nil }
      return summary
    }
    let summary = try XCTUnwrap(summaries.first)
    XCTAssertTrue(summary.contains("-32603"))
    XCTAssertTrue(summary.contains("service_overloaded"))
    XCTAssertFalse(summary.contains("fixture-secret-value"))
  }

  private enum Scenario: Sendable {
    case unknownStopReason
    case maxTokens
    case unfinishedTool
    case reasoningOnly
    case normal
    case providerError
  }

  private func run(scenario: Scenario) async throws -> [AgentEventEnvelope] {
    let transport = ScriptedACPTransport()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(Self.initializationResult(id: id))
      case "session/new":
        try await transport.emit(Self.sessionResult(id: id))
      case "session/set_config_option":
        try await transport.emit(
          ACPWireMessage(id: id, result: .object(["configOptions": .array([])]))
        )
      case "session/prompt":
        try await Self.emitPromptScenario(scenario, id: id, transport: transport)
      default:
        break
      }
    }

    let projectRoot = try makeTemporaryDirectory(prefix: "opencode-execution-project")
    let sourceHome = try makeTemporaryDirectory(prefix: "opencode-execution-home")
    let runtimeBase = temporaryPath(prefix: "opencode-execution-runtime")
    defer {
      for path in [projectRoot, sourceHome, runtimeBase] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }

    let provider = try OpenCodeACPProvider(
      configuration: OpenCodeACPProviderConfiguration(
        runtimeBaseDirectory: runtimeBase,
        sourceEnvironment: ["HOME": sourceHome],
        transportFactory: { _ in transport }
      )
    )
    let handle = try await provider.start(
      try AgentExecutionRequest(
        taskID: TaskID(rawValue: "task-opencode-state"),
        projectID: ProjectID(rawValue: "project-opencode-state"),
        projectRoot: projectRoot,
        prompt: "Inspect the project.",
        mutationIntent: .readOnly,
        workspaceStrategy: .sharedProject,
        networkAccessRequested: false
      ),
      installation: try AgentInstallation(
        id: AgentInstallationID(rawValue: "installation-opencode-state"),
        providerID: .openCode,
        executablePath: "/bin/echo"
      )
    )

    var events: [AgentEventEnvelope] = []
    for try await event in handle.events {
      events.append(event)
    }
    return events
  }

  private static func emitPromptScenario(
    _ scenario: Scenario,
    id: ACPRequestID,
    transport: ScriptedACPTransport
  ) async throws {
    switch scenario {
    case .providerError:
      try await transport.emit(
        ACPWireMessage(
          id: id,
          error: .init(
            code: -32603,
            message: "Internal error",
            data: .object([
              "message": .string("service_overloaded; api_key=fixture-secret-value")
            ])
          )
        )
      )
    case .unknownStopReason:
      try await transport.emit(
        ACPWireMessage(id: id, result: .object(["stopReason": .string("provider_paused")]))
      )
    case .maxTokens:
      try await transport.emit(messageUpdate(text: "Partial answer"))
      try await transport.emit(
        ACPWireMessage(id: id, result: .object(["stopReason": .string("max_tokens")]))
      )
    case .unfinishedTool:
      try await transport.emit(toolUpdate(status: "in_progress"))
      try await transport.emit(messageUpdate(text: "Partial answer"))
      try await transport.emit(
        ACPWireMessage(id: id, result: .object(["stopReason": .string("end_turn")]))
      )
    case .reasoningOnly:
      try await transport.emit(reasoningUpdate(text: "Hidden reasoning"))
      try await transport.emit(
        ACPWireMessage(id: id, result: .object(["stopReason": .string("end_turn")]))
      )
    case .normal:
      try await transport.emit(toolUpdate(status: "in_progress"))
      try await transport.emit(toolUpdate(status: "completed"))
      try await transport.emit(messageUpdate(text: "Final answer"))
      try await transport.emit(
        ACPWireMessage(id: id, result: .object(["stopReason": .string("end_turn")]))
      )
    }
  }

  private static func initializationResult(id: ACPRequestID) -> ACPWireMessage {
    ACPWireMessage(
      id: id,
      result: .object([
        "protocolVersion": .integer(1),
        "agentCapabilities": .object([:]),
        "agentInfo": .object([
          "name": .string("OpenCode"),
          "title": .string("OpenCode"),
          "version": .string("1.18.23"),
        ]),
      ])
    )
  }

  private static func sessionResult(id: ACPRequestID) -> ACPWireMessage {
    ACPWireMessage(
      id: id,
      result: .object([
        "sessionId": .string("session-state"),
        "configOptions": .array([
          .object([
            "id": .string("mode"),
            "name": .string("Mode"),
            "type": .string("select"),
            "currentValue": .string("plan"),
            "options": .array([
              .object(["value": .string("plan"), "name": .string("Plan")]),
              .object(["value": .string("build"), "name": .string("Build")]),
            ]),
          ])
        ]),
      ])
    )
  }

  private static func messageUpdate(text: String) -> ACPWireMessage {
    ACPWireMessage(
      method: "session/update",
      params: .object([
        "sessionId": .string("session-state"),
        "update": .object([
          "sessionUpdate": .string("agent_message_chunk"),
          "messageId": .string("message-state"),
          "content": .object([
            "type": .string("text"),
            "text": .string(text),
          ]),
        ]),
      ])
    )
  }

  private static func reasoningUpdate(text: String) -> ACPWireMessage {
    ACPWireMessage(
      method: "session/update",
      params: .object([
        "sessionId": .string("session-state"),
        "update": .object([
          "sessionUpdate": .string("agent_thought_chunk"),
          "messageId": .string("reasoning-state"),
          "content": .object([
            "type": .string("text"),
            "text": .string(text),
          ]),
        ]),
      ])
    )
  }

  private static func toolUpdate(status: String) -> ACPWireMessage {
    ACPWireMessage(
      method: "session/update",
      params: .object([
        "sessionId": .string("session-state"),
        "update": .object([
          "sessionUpdate": .string("tool_call_update"),
          "toolCallId": .string("tool-state"),
          "title": .string("Run command"),
          "kind": .string("execute"),
          "status": .string(status),
        ]),
      ])
    )
  }

  private func assertFailure(
    _ events: [AgentEventEnvelope],
    code: String,
    message: String
  ) {
    XCTAssertFalse(
      events.contains { envelope in
        if case .completed = envelope.event { return true }
        return false
      })
    guard
      let failure = events.compactMap({ envelope -> (String, String)? in
        guard case .failed(let code, let summary) = envelope.event else { return nil }
        return (code, summary)
      }).first
    else {
      return XCTFail("Expected a failed terminal event")
    }
    XCTAssertEqual(failure.0, code)
    XCTAssertEqual(failure.1, message)
  }

  private func makeTemporaryDirectory(prefix: String) throws -> String {
    let path = temporaryPath(prefix: prefix)
    try FileManager.default.createDirectory(
      atPath: path,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    return path
  }

  private func temporaryPath(prefix: String) -> String {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true).path
  }
}

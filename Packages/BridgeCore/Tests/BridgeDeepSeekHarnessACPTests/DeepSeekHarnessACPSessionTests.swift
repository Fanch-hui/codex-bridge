import BridgeACP
import BridgeAgentCore
import BridgeDomain
import Foundation
import XCTest

@testable import BridgeDeepSeekHarnessACP

final class DeepSeekHarnessACPSessionTests: XCTestCase {
  func testInitializationExposesModernSessionAndMCPCapabilities() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    await transport.setHandler { message, transport in
      guard message.method == "initialize", let id = message.id else { return }
      try await transport.emit(deepSeekInitializationResult(id: id, modernCapabilities: true))
    }
    let client = DeepSeekHarnessACPClient(
      transport: transport,
      clientInfo: .init(name: "tests", title: "Tests", version: "1")
    )
    addTeardownBlock { await client.shutdown() }

    let initialization = try await client.initialize()

    XCTAssertTrue(initialization.supportsResumeSession)
    XCTAssertTrue(initialization.supportsCloseSession)
    XCTAssertTrue(initialization.supportsMCPHTTP)
  }

  func testResumeAndCloseReplaceMCPConfigurationAcrossProcesses() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id, modernCapabilities: true))
      case "session/resume":
        try await transport.emit(
          deepSeekSessionResult(
            id: id,
            sessionID: "persisted-session",
            configOptions: deepSeekModelConfigOptions()
          )
        )
      case "session/close":
        try await transport.emit(ACPWireMessage(id: id, result: .object([:])))
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
    let mcpServers: [ACPJSONValue] = [
      .object([
        "name": .string("workspace-tools"),
        "command": .string("/usr/local/bin/mcp-server"),
        "args": .array([.string("--stdio")]),
      ])
    ]
    let session = try await client.resumeSession(
      id: "persisted-session",
      cwd: "/tmp/project",
      mcpServers: mcpServers
    )
    XCTAssertEqual(session.id, "persisted-session")
    try await client.closeSession(id: session.id)

    let sent = await transport.sentMessages()
    let resume = try XCTUnwrap(sent.first { $0.method == "session/resume" })
    XCTAssertEqual(resume.params?["sessionId"], .string("persisted-session"))
    XCTAssertEqual(resume.params?["cwd"], .string("/tmp/project"))
    XCTAssertEqual(resume.params?["mcpServers"], .array(mcpServers))
    let close = try XCTUnwrap(sent.first { $0.method == "session/close" })
    XCTAssertEqual(close.params?["sessionId"], .string("persisted-session"))
  }

  func testResumeRequiresAdvertisedCapability() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    await transport.setHandler { message, transport in
      guard message.method == "initialize", let id = message.id else { return }
      try await transport.emit(
        ACPWireMessage(id: id, result: .object(["protocolVersion": .integer(1)]))
      )
    }
    let client = DeepSeekHarnessACPClient(
      transport: transport,
      clientInfo: .init(name: "tests", title: "Tests", version: "1")
    )
    addTeardownBlock { await client.shutdown() }
    _ = try await client.initialize()

    do {
      _ = try await client.resumeSession(id: "persisted", cwd: "/tmp/project")
      XCTFail("Expected resume capability rejection")
    } catch let error as AgentRuntimeError {
      XCTAssertEqual(error, .capabilityUnavailable(.sessionContinue))
    }
  }

  func testResumeAppliesExplicitOpaqueModelAndEffortSelection() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id, modernCapabilities: true))
      case "session/resume":
        try await transport.emit(
          deepSeekSessionResult(
            id: id,
            sessionID: "selection-session",
            configOptions: sessionSelectionOptions()
          )
        )
      case "session/set_config_option":
        try await transport.emit(
          ACPWireMessage(
            id: id,
            result: .object(["configOptions": .array(sessionSelectionOptions())])
          )
        )
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
    let session = try await client.resumeSession(id: "selection-session", cwd: "/tmp/project")
    let provider = try DeepSeekHarnessACPProvider()
    let request = try AgentExecutionRequest(
      taskID: .init(rawValue: "selection-task"),
      projectID: .init(rawValue: "selection-project"),
      projectRoot: "/tmp/project",
      prompt: "continue",
      requestedSessionID: session.id,
      model: "deepseek-v4-pro",
      effort: "low",
      mutationIntent: .readOnly,
      workspaceStrategy: .sharedProject,
      networkAccessRequested: false
    )

    try await provider.applyRequestedSelection(
      request: request,
      session: session,
      client: client
    )

    let sent = await transport.sentMessages()
    let model = try XCTUnwrap(
      sent.first {
        $0.method == "session/set_config_option" && $0.params?["configId"] == .string("model")
      }
    )
    XCTAssertEqual(model.params?["value"], .string(#"["deepseek-official","deepseek-v4-pro"]"#))
    let effort = try XCTUnwrap(
      sent.first {
        $0.method == "session/set_config_option"
          && $0.params?["configId"] == .string("reasoning_effort")
      }
    )
    XCTAssertEqual(effort.params?["value"], .string("low"))
  }
}

private func sessionSelectionOptions() -> [ACPJSONValue] {
  [
    .object([
      "id": .string("model"),
      "category": .string("model"),
      "currentValue": .string(#"["deepseek-official","deepseek-v4-pro"]"#),
      "options": .array([
        .object([
          "value": .string(#"["deepseek-official","deepseek-v4-pro"]"#),
          "name": .string("DeepSeek V4 Pro"),
        ])
      ]),
    ]),
    .object([
      "id": .string("reasoning_effort"),
      "category": .string("thought_level"),
      "currentValue": .string("high"),
      "options": .array([
        .object(["value": .string("low"), "name": .string("Low")]),
        .object(["value": .string("high"), "name": .string("High")]),
      ]),
    ]),
  ]
}

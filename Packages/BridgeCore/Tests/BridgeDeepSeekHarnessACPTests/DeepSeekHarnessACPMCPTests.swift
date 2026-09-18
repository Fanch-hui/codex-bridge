import BridgeACP
import BridgeAgentCore
import XCTest

@testable import BridgeDeepSeekHarnessACP

final class DeepSeekHarnessACPMCPTests: XCTestCase {
  func testMCPParametersUseStandardTransportsAndTaskNetworkPermission() throws {
    let initialization = DeepSeekHarnessACPInitialization(
      protocolVersion: 1, agentName: "deepseek-harness-acp", agentTitle: nil, agentVersion: "1",
      supportsMCPHTTP: true
    )
    let servers: [AgentMCPServerConfiguration] = [
      .init(
        id: "local", name: "local", transport: .stdio, command: "/usr/bin/node",
        args: ["server.js"], environment: ["API_KEY": "fixture-value"]),
      .init(
        id: "remote", name: "remote", transport: .http, url: "https://example.test/mcp",
        headers: ["Authorization": "Bearer fixture-value"]),
    ]
    let local = try DeepSeekHarnessACPMCP.parameters(
      servers: servers, initialization: initialization, networkAllowed: false
    )
    XCTAssertEqual(local.count, 1)
    XCTAssertNil(local[0]["type"])
    XCTAssertEqual(local[0]["env"]?.arrayValue?.first?["value"]?.stringValue, "fixture-value")
    let all = try DeepSeekHarnessACPMCP.parameters(
      servers: servers, initialization: initialization, networkAllowed: true
    )
    XCTAssertEqual(all.count, 2)
    XCTAssertEqual(all[1]["type"]?.stringValue, "http")
    XCTAssertEqual(all[1]["headers"]?.arrayValue?.first?["name"]?.stringValue, "Authorization")
  }

  func testStdioOnlyMCPDoesNotRequireHTTPCapability() throws {
    let initialization = DeepSeekHarnessACPInitialization(
      protocolVersion: 1,
      agentName: "deepseek-harness-acp",
      agentTitle: nil,
      agentVersion: "1",
      supportsMCPHTTP: false
    )
    let servers: [AgentMCPServerConfiguration] = [
      .init(
        id: "local",
        name: "local",
        transport: .stdio,
        command: "/usr/bin/node",
        args: ["server.js"]
      )
    ]

    let values = try DeepSeekHarnessACPMCP.parameters(
      servers: servers,
      initialization: initialization,
      networkAllowed: false
    )

    XCTAssertEqual(values.count, 1)
    XCTAssertEqual(values[0]["command"]?.stringValue, "/usr/bin/node")
  }
}

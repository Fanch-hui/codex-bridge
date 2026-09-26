import Foundation
import MCP
import XCTest

@testable import BridgeMCP

final class MCPToolContractTests: XCTestCase {
  func testServiceListAgentsSchemaDocumentsProviderCapabilitiesAndNetworkBoundary() throws {
    let definitions = MCPServiceToolCatalog(exposureMode: .readOnly).definitions
    let definition = try XCTUnwrap(
      definitions.first(where: { $0.name == MCPServiceToolName.listAgents.rawValue })
    )
    let agentProperties = try XCTUnwrap(
      definition.outputSchema?.objectValue?["properties"]?.objectValue?["agents"]?
        .objectValue?["items"]?
        .objectValue?["properties"]?.objectValue
    )
    let providerDescription = try XCTUnwrap(
      agentProperties["provider_id"]?.objectValue?["description"]?.stringValue
    )
    let capabilityDescription = try XCTUnwrap(
      agentProperties["effective_capabilities"]?.objectValue?["description"]?.stringValue
    )
    let networkDescription = try XCTUnwrap(
      agentProperties["network_enforcement"]?.objectValue?["description"]?.stringValue
    )

    XCTAssertTrue(providerDescription.contains("deepseek-harness"))
    XCTAssertTrue(capabilityDescription.contains("tools.web_search"))
    XCTAssertTrue(capabilityDescription.contains("approval"))
    XCTAssertTrue(capabilityDescription.contains("lifecycle"))
    XCTAssertTrue(capabilityDescription.contains("Provider-native tools"))
    XCTAssertTrue(networkDescription.contains("provider_native"))

    let instructions = MCPServiceServerFactory.instructions(customInstructions: "")
    XCTAssertTrue(instructions.contains("provider_id=deepseek-harness"))
    XCTAssertTrue(instructions.contains("execution-time permission requests are surfaced"))
    XCTAssertTrue(instructions.contains("workspace-write"))
    XCTAssertTrue(instructions.contains("queued follow-up"))
    XCTAssertTrue(instructions.contains("Provider-native policy"))
    XCTAssertTrue(instructions.contains("Web, network, MCP, file, command"))

    let submit = try XCTUnwrap(
      MCPServiceToolCatalog(exposureMode: .full).definitions.first(where: {
        $0.name == MCPServiceToolName.submitTask.rawValue
      })
    )
    XCTAssertTrue(
      submit.description?.contains("Web, network, MCP, file, command") == true)
    XCTAssertTrue(submit.description?.contains("not the global custom instructions") == true)
    XCTAssertTrue(submit.description?.contains("concrete task") == true)
    XCTAssertFalse(
      submit.description?.localizedCaseInsensitiveContains(
        "does not provide Web search"
      ) == true
    )
    let steer = try XCTUnwrap(
      MCPServiceToolCatalog(exposureMode: .full).definitions.first(where: {
        $0.name == MCPServiceToolName.steerTask.rawValue
      })
    )
    XCTAssertTrue(steer.description?.contains("not global custom instructions") == true)
  }

  func testServiceCatalogPublishesStrictClosedSchemasAndExposureBoundaries() throws {
    let readOnly = MCPServiceToolCatalog(exposureMode: .readOnly).definitions
    let full = MCPServiceToolCatalog(exposureMode: .full).definitions

    XCTAssertTrue(readOnly.count < full.count)
    XCTAssertEqual(Set(full.map(\.name)), Set(MCPServiceToolName.allCases.map(\.rawValue)))
    XCTAssertTrue(readOnly.allSatisfy { $0.annotations.readOnlyHint == true })
    XCTAssertFalse(readOnly.contains { $0.name == MCPServiceToolName.submitTask.rawValue })
    XCTAssertTrue(full.contains { $0.name == MCPServiceToolName.submitTask.rawValue })
    let statusProperties = try XCTUnwrap(
      readOnly.first(where: { $0.name == MCPServiceToolName.bridgeStatus.rawValue })?
        .outputSchema?.objectValue?["properties"]?.objectValue
    )
    XCTAssertNotNil(statusProperties["codex_version"])
    XCTAssertNotNil(statusProperties["login_mode"])

    for definition in full {
      XCTAssertEqual(definition.annotations.openWorldHint, false)
      try assertObjectSchemasAreClosed(definition.inputSchema)
      try assertObjectSchemasAreClosed(XCTUnwrap(definition.outputSchema))
    }
  }

  func testGetTaskSchemaIncludesProviderUsageStatistics() throws {
    let definition = try XCTUnwrap(
      MCPServiceToolCatalog(exposureMode: .readOnly).definitions.first(where: {
        $0.name == MCPServiceToolName.getTask.rawValue
      })
    )
    let taskProperties = try XCTUnwrap(
      definition.outputSchema?.objectValue?["properties"]?.objectValue?[
        "task"]?.objectValue?["properties"]?.objectValue
    )
    let usage = try XCTUnwrap(taskProperties["usage"]?.objectValue)
    XCTAssertEqual(usage["type"]?.arrayValue, [.string("object"), .string("null")])
    XCTAssertEqual(usage["additionalProperties"], .bool(false))

    let properties = try XCTUnwrap(usage["properties"]?.objectValue)
    for name in [
      "inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens", "totalTokens",
      "contextTokens", "contextWindow", "contextUsedPercentage", "costAmount", "currency",
    ] {
      XCTAssertNotNil(properties[name], "Missing usage schema property: \(name)")
    }
    XCTAssertEqual(
      properties["contextUsedPercentage"]?.objectValue?["type"]?.arrayValue,
      [.string("number"), .string("null")]
    )
    XCTAssertNotNil(taskProperties["attachment_paths"])
  }

  func testTaskSnapshotDecodesBeforeAttachmentPathsWereAdded() throws {
    let snapshot = MCPServiceTaskSnapshot(
      taskID: "task-1",
      projectID: "project-1",
      status: "completed",
      supervisorStatus: "none",
      localApprovalRequired: false,
      updatedAt: "2026-09-26T00:00:00Z"
    )
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
    )
    object.removeValue(forKey: "attachment_paths")

    let decoded = try JSONDecoder().decode(
      MCPServiceTaskSnapshot.self,
      from: JSONSerialization.data(withJSONObject: object)
    )
    XCTAssertEqual(decoded.attachmentPaths, [])
  }

  func testModelSummaryDecodesPayloadWithoutDefaultEffort() throws {
    let data = Data(
      #"""
      {"model_id":"model","display_name":"Model","is_default":false,"reasoning_efforts":["medium"]}
      """#.utf8
    )
    let model = try JSONDecoder().decode(MCPModelSummary.self, from: data)

    XCTAssertNil(model.defaultReasoningEffort)
    let encoded = try JSONEncoder().encode(model)
    XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("default_reasoning_effort"))
  }

  func testResultEncoderEnforcesConfiguredByteLimit() throws {
    let encoder = MCPToolResultEncoder(maximumBytes: 128)

    XCTAssertThrowsError(try encoder.encode(["value": String(repeating: "x", count: 256)])) {
      XCTAssertEqual(
        $0 as? MCPToolResultEncodingError,
        .resultTooLarge(maximumBytes: 128)
      )
    }
  }

  private func assertObjectSchemasAreClosed(
    _ value: Value,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    switch value {
    case .array(let values):
      for child in values {
        try assertObjectSchemasAreClosed(child, file: file, line: line)
      }
    case .object(let object):
      if object["type"] == "object" {
        switch object["additionalProperties"] {
        case .bool(false):
          break
        case .object(let schema):
          try assertObjectSchemasAreClosed(.object(schema), file: file, line: line)
        default:
          XCTFail("Object schema must bound additional properties.", file: file, line: line)
        }
      }
      for child in object.values {
        try assertObjectSchemasAreClosed(child, file: file, line: line)
      }
    default:
      break
    }
  }
}

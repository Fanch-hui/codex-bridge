import BridgeACP
import BridgeAgentCore
import Foundation
import XCTest

@testable import BridgeDeepSeekHarnessACP

final class DeepSeekHarnessACPModernModelTests: XCTestCase {
  func testModernProviderGroupsFlattenAndAllowEmptyProviderDefault() throws {
    let parsed = try DeepSeekHarnessACPClient.parseConfigOptions(
      .array(modernConfigOptions())
    )

    XCTAssertEqual(parsed[0].id, "model")
    XCTAssertEqual(
      parsed[0].values.map(\.value),
      [
        #"["deepseek-official","deepseek-v4-flash"]"#,
        #"["deepseek-official","deepseek-v4-pro"]"#,
        #"["gateway","gateway-v4-flash"]"#,
      ]
    )
    XCTAssertEqual(parsed[1].currentValue, "")
    XCTAssertEqual(parsed[1].values.map(\.value), ["", "low", "high"])
  }

  func testModernModelValuesBecomeLaunchModelIDsAndUseSelectedThoughtLevel() throws {
    let options = try DeepSeekHarnessACPClient.parseConfigOptions(
      .array(modernConfigOptions(currentThoughtLevel: "low"))
    )
    let fallback = [
      try AgentModelDescriptor(
        id: "deepseek-v4-flash",
        displayName: "DeepSeek V4 Flash",
        supportedReasoningEfforts: ["off", "low", "high", "max"],
        defaultReasoningEffort: "max"
      )
    ]

    let models = try DeepSeekHarnessACPProvider.modelDescriptors(
      from: options,
      selectedModelID: "deepseek-v4-pro",
      fallback: fallback
    )

    XCTAssertEqual(models.map(\.id), ["deepseek-v4-flash", "deepseek-v4-pro", "gateway-v4-flash"])
    XCTAssertEqual(models[1].supportedReasoningEfforts, ["low", "high"])
    XCTAssertEqual(models[1].defaultReasoningEffort, "low")
    XCTAssertEqual(models[0].supportedReasoningEfforts, [])
    XCTAssertNil(models[0].defaultReasoningEffort)
  }

  func testLegacyFlatModelValuesKeepTheirExistingIDsAndFallbackEfforts() throws {
    let options = [
      DeepSeekHarnessACPConfigOption(
        id: "model",
        category: "model",
        currentValue: "deepseek-v4-pro",
        values: [
          .init(value: "deepseek-v4-pro", name: "DeepSeek V4 Pro"),
          .init(value: "gateway-new", name: "Gateway New"),
        ]
      )
    ]
    let fallback = [
      try AgentModelDescriptor(
        id: "deepseek-v4-pro",
        displayName: "DeepSeek V4 Pro",
        supportedReasoningEfforts: ["off", "low", "high", "max"],
        defaultReasoningEffort: "max"
      )
    ]

    let models = try DeepSeekHarnessACPProvider.modelDescriptors(
      from: options,
      selectedModelID: "gateway-new",
      fallback: fallback
    )

    XCTAssertEqual(models.map(\.id), ["deepseek-v4-pro", "gateway-new"])
    XCTAssertEqual(models[1].supportedReasoningEfforts, ["off", "low", "high", "max"])
    XCTAssertEqual(models[1].defaultReasoningEffort, "max")
  }

  func testClientSendsOpaqueModernModelValueBackToACP() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    let selectedWireValue = #"["deepseek-official","deepseek-v4-pro"]"#
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id))
      case "session/new":
        try await transport.emit(
          deepSeekSessionResult(
            id: id,
            sessionID: "modern-model-session",
            configOptions: modernConfigOptions()
          )
        )
      case "session/set_config_option":
        try await transport.emit(
          ACPWireMessage(
            id: id,
            result: .object([
              "configOptions": .array(modernConfigOptions(currentModel: selectedWireValue))
            ])
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
    let session = try await client.newSession(cwd: "/tmp")
    _ = try await client.setSessionConfigOption(
      sessionID: session.id,
      configID: "model",
      value: selectedWireValue
    )

    let sent = await transport.sentMessages()
    let setRequest = try XCTUnwrap(sent.first { $0.method == "session/set_config_option" })
    XCTAssertEqual(setRequest.params?["value"]?.stringValue, selectedWireValue)
  }
}

private func modernConfigOptions(
  currentModel: String = #"["deepseek-official","deepseek-v4-flash"]"#,
  currentThoughtLevel: String = ""
) -> [ACPJSONValue] {
  [
    .object([
      "id": .string("model"),
      "name": .string("Model"),
      "category": .string("model"),
      "type": .string("select"),
      "currentValue": .string(currentModel),
      "options": .array([
        .object([
          "group": .string("deepseek-official"),
          "name": .string("DeepSeek"),
          "options": .array([
            .object([
              "value": .string(#"["deepseek-official","deepseek-v4-flash"]"#),
              "name": .string("DeepSeek V4 Flash"),
            ]),
            .object([
              "value": .string(#"["deepseek-official","deepseek-v4-pro"]"#),
              "name": .string("DeepSeek V4 Pro"),
            ]),
          ]),
        ]),
        .object([
          "group": .string("gateway"),
          "name": .string("Gateway"),
          "options": .array([
            .object([
              "value": .string(#"["gateway","gateway-v4-flash"]"#),
              "name": .string("Gateway Flash"),
            ])
          ]),
        ]),
      ]),
    ]),
    .object([
      "id": .string("reasoning_effort"),
      "name": .string("Reasoning effort"),
      "category": .string("thought_level"),
      "type": .string("select"),
      "currentValue": .string(currentThoughtLevel),
      "options": .array([
        .object(["value": .string(""), "name": .string("Provider default")]),
        .object(["value": .string("low"), "name": .string("Low")]),
        .object(["value": .string("high"), "name": .string("High")]),
      ]),
    ]),
  ]
}

import BridgeAgentCore
import BridgeDomain
import Foundation
import Testing

@testable import BridgePiRPC

struct PiExtensionUserInputBridgeTests {
  private let taskID = TaskID(rawValue: "pi-input-task")

  private func makeBinding() throws -> AgentBinding {
    try AgentBinding(
      providerID: .pi,
      installationID: AgentInstallationID(rawValue: "pi-installation"),
      providerSessionID: "session", providerRunID: "run")
  }

  @Test func mapsNativeSelectAndConfirmationAnswers() throws {
    let binding = try makeBinding()
    let parsedSelection = try PiExtensionUserInputBridge.request(
      .object([
        "id": .string("select-1"), "method": .string("select"),
        "title": .string("Choose a model"),
        "options": .array([.string("model-a"), .string("model-b")]),
        "timeout": .integer(1_500),
      ]), taskID: taskID, binding: binding)
    let selection = try #require(parsedSelection)
    #expect(selection.request.timeoutSeconds == 2)
    #expect(selection.request.questions[0].kind == .select)
    #expect(
      try selection.responseFields(for: .answers(["answer": ["model-b"]]))
        == ["value": .string("model-b")])
    #expect(throws: AgentRuntimeError.invalidRequest("pi.user_input_answer")) {
      try selection.responseFields(for: .answers(["answer": ["other"]]))
    }

    let parsedConfirmation = try PiExtensionUserInputBridge.request(
      .object([
        "id": .string("confirm-1"), "method": .string("confirm"),
        "title": .string("Apply changes?"), "message": .string("Update the project"),
      ]),
      taskID: taskID, binding: binding)
    let confirmation = try #require(parsedConfirmation)
    #expect(
      try confirmation.responseFields(for: .answers(["answer": ["是"]]))
        == ["confirmed": .bool(true)])
    #expect(
      try confirmation.responseFields(for: .answers(["answer": ["否"]]))
        == ["confirmed": .bool(false)])
  }

  @Test func mapsTextEditorsAndCancellation() throws {
    let binding = try makeBinding()
    for method in ["input", "editor"] {
      let parsed = try PiExtensionUserInputBridge.request(
        .object([
          "id": .string("text-\(method)"), "method": .string(method),
          "title": .string("Provide details"), "prefill": .string("current value"),
        ]),
        taskID: taskID, binding: binding)
      let input = try #require(parsed)
      #expect(input.request.questions[0].kind.rawValue == method)
      #expect(input.request.questions[0].question.contains("current value") == (method == "editor"))
      #expect(
        try input.responseFields(for: .answers(["answer": ["updated"]]))
          == ["value": .string("updated")])
      #expect(try input.responseFields(for: .cancelled) == ["cancelled": .bool(true)])
    }
  }

  @Test func mapsStructuredQuestionnairesAndAnswers() throws {
    let binding = try makeBinding()
    let payload = PiJSONValue.object([
      "revision": .integer(1), "title": .string("Pi 有 2 个问题"),
      "summary": .string("配置 · 备注"), "timeoutSeconds": .integer(90),
      "questions": .array([
        .object([
          "id": .string("backend"), "header": .string("配置"),
          "question": .string("选择后端"), "kind": .string("select"),
          "options": .array([
            .object(["label": .string("A"), "description": .string("本地")]),
            .object(["label": .string("B"), "description": .string("远端")]),
          ]),
          "allowsMultiple": .bool(true), "allowsCustomText": .bool(false),
          "isSecret": .bool(false), "isRequired": .bool(true),
        ]),
        .object([
          "id": .string("notes"), "header": .string("备注"),
          "question": .string("提供备注"), "kind": .string("input"),
          "options": .array([]), "allowsMultiple": .bool(false),
          "allowsCustomText": .bool(true), "isSecret": .bool(true),
          "isRequired": .bool(false),
        ]),
      ]),
    ])
    let title = "codex-bridge.pi.questionnaire.v1:" + (try payload.text())
    let parsed = try PiExtensionUserInputBridge.request(
      .object([
        "id": .string("questionnaire-1"), "method": .string("input"),
        "title": .string(title),
      ]), taskID: taskID, binding: binding)
    let input = try #require(parsed)
    #expect(input.request.questions.count == 2)
    #expect(input.request.questions[0].allowsMultiple)
    #expect(input.request.questions[1].isSecret)
    #expect(!input.request.questions[1].isRequired)

    let fields = try input.responseFields(
      for: .answers([
        "backend": ["A", "B"], "notes": ["private note"],
      ]))
    let encoded = try #require(fields["value"]?.stringValue)
    let value = try JSONDecoder().decode(PiJSONValue.self, from: Data(encoded.utf8))
    #expect(value["answers"]?["backend"]?.arrayValue == [.string("A"), .string("B")])
    #expect(value["answers"]?["notes"]?.arrayValue == [.string("private note")])
    #expect(throws: AgentRuntimeError.invalidRequest("pi.user_input_answer")) {
      try input.responseFields(for: .answers(["backend": ["unknown"]]))
    }
  }
}

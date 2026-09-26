import BridgeACP
import BridgeAgentCore
import BridgeDomain
import Foundation
import Testing

@testable import BridgeQoderSDK

struct QoderUserInputRoundTripTests {
  @Test func returnsIndexedAnswerArraysToHost() async throws {
    let transport = QuestionTransport()
    let client = QoderSDKClient(transport: transport, requestTimeout: .seconds(5))
    let request = try AgentExecutionRequest(
      taskID: TaskID(rawValue: "question-task"), projectID: ProjectID(rawValue: "question-project"),
      projectRoot: FileManager.default.temporaryDirectory.path, prompt: "Ask a question",
      mutationIntent: .readOnly, workspaceStrategy: .sharedProject, networkAccessRequested: false)
    let binding = try AgentBinding(
      providerID: .qoder, installationID: AgentInstallationID(rawValue: "qoder-installation"),
      providerSessionID: UUID().uuidString.lowercased(), providerRunID: "question-run")
    let execution = QoderSDKExecution(
      client: client, request: request, binding: binding, distribution: .cn)
    await execution.start()
    var events = execution.events.makeAsyncIterator()
    let next = try await events.next()
    let envelope = try #require(next)
    guard case .userInputRequested(let input) = envelope.event else {
      Issue.record("Expected structured question")
      await execution.shutdown()
      return
    }
    #expect(input.questions[0].allowsCustomText)
    try await execution.resolveUserInput(
      input.inputID, response: .answers(["0": ["Custom answer"]]))
    let answer = await transport.answer
    #expect(answer?["answers"]?["0"] == .array([.string("Custom answer")]))
    #expect(answer?["answers"]?["Choose?"] == nil)
    await execution.shutdown()
  }
}

private actor QuestionTransport: ACPTransport {
  nonisolated let incoming: AsyncThrowingStream<Data, any Error>
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private(set) var answer: ACPJSONValue?

  init() {
    let stream = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
    incoming = stream.stream
    continuation = stream.continuation
  }

  func send(_ frame: Data) throws {
    let message = try JSONDecoder().decode(ACPWireMessage.self, from: frame)
    if message.method == "qoder/input", let id = message.id {
      try emit(
        ACPWireMessage(
          id: id,
          result: .object([
            "accepted": .bool(true), "inputID": message.params?["id"] ?? .null,
          ])))
      try emit(
        ACPWireMessage(
          id: .string("host-question"), method: "qoder/question",
          params: .object([
            "toolUseID": .string("ask-tool"),
            "questions": .array([
              .object([
                "question": .string("Choose?"), "header": .string("Choice"),
                "options": .array([
                  .object(["label": .string("One")]), .object(["label": .string("Two")]),
                ]),
              ])
            ]),
          ])))
    } else if message.id == .string("host-question") {
      answer = message.result
    } else if let id = message.id {
      try emit(ACPWireMessage(id: id, result: .object(["closed": .bool(true)])))
    }
  }

  func close() { continuation.finish() }

  private func emit(_ message: ACPWireMessage) throws {
    continuation.yield(try JSONEncoder().encode(message))
  }
}

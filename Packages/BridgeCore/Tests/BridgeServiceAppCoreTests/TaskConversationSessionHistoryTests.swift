import BridgeIPC
import XCTest

@testable import BridgeServiceAppCore

private actor SessionHistoryClient: BridgeTaskConversationClient {
  let pages: [String: IPCTaskConversationPage]

  init(pages: [String: IPCTaskConversationPage]) {
    self.pages = pages
  }

  func taskConversation(_ request: IPCTaskConversationRequest) async throws
    -> IPCTaskConversationPage
  {
    pages[request.taskID] ?? IPCTaskConversationPage(taskID: request.taskID, messages: [])
  }

  func subscribeTaskConversation(
    taskID: String,
    limit _: Int
  ) async throws -> (IPCTaskConversationSubscription, AsyncStream<IPCTaskConversationPush>) {
    let page = pages[taskID] ?? IPCTaskConversationPage(taskID: taskID, messages: [])
    let updates = AsyncStream<IPCTaskConversationPush> { continuation in
      continuation.finish()
    }
    return (
      IPCTaskConversationSubscription(subscriptionID: 1, page: page),
      updates
    )
  }

  func unsubscribeTaskConversation(taskID _: String, subscriptionID _: Int) async throws {}
}

@MainActor
final class TaskConversationSessionHistoryTests: XCTestCase {
  func testTerminalConversationPrependsPriorTurnsWithStableKeys() async {
    let prior = IPCTaskConversationPage(
      taskID: "task-prior",
      messages: [
        IPCTaskConversationMessage(
          messageID: 1,
          key: "user:1",
          role: "user",
          content: "第一轮"
        ),
        IPCTaskConversationMessage(
          messageID: 2,
          key: "agent:1",
          role: "agent",
          content: "第一轮结果"
        ),
      ]
    )
    let current = IPCTaskConversationPage(
      taskID: "task-current",
      messages: [
        IPCTaskConversationMessage(
          messageID: 3,
          key: "user:1",
          role: "user",
          content: "第二轮"
        ),
        IPCTaskConversationMessage(
          messageID: 4,
          key: "agent:1",
          role: "agent",
          content: "第二轮结果"
        ),
      ]
    )
    let client = SessionHistoryClient(pages: [
      prior.taskID: prior,
      current.taskID: current,
    ])
    let model = TaskConversationModel(
      taskID: current.taskID,
      priorTaskIDs: [prior.taskID],
      client: client,
      isTerminal: true
    )

    await model.start()

    XCTAssertEqual(
      model.entries.map(\.key),
      ["task-prior:user:1", "task-prior:agent:1", "user:1", "agent:1"]
    )
    XCTAssertEqual(
      model.entries.map(\.content),
      ["第一轮", "第一轮结果", "第二轮", "第二轮结果"]
    )
    XCTAssertTrue(model.entries.allSatisfy(\.isFinal))
  }

  func testRestoredPriorHistoryIsReplacedInsteadOfDuplicated() async {
    let priorMessage = IPCTaskConversationMessage(
      messageID: 1,
      key: "user:1",
      role: "user",
      content: "服务端第一轮"
    )
    let currentMessage = IPCTaskConversationMessage(
      messageID: 2,
      key: "agent:1",
      role: "agent",
      content: "服务端第二轮"
    )
    let client = SessionHistoryClient(pages: [
      "task-prior": IPCTaskConversationPage(
        taskID: "task-prior",
        messages: [priorMessage]
      ),
      "task-current": IPCTaskConversationPage(
        taskID: "task-current",
        messages: [currentMessage]
      ),
    ])
    let model = TaskConversationModel(
      taskID: "task-current",
      priorTaskIDs: ["task-prior"],
      client: client,
      isTerminal: true
    )
    model.restorePresentation(
      TaskConversationPresentationSnapshot(
        entries: [
          TaskConversationModel.Entry(
            priorMessage,
            isFinal: true,
            keyPrefix: "task-prior"
          ),
          TaskConversationModel.Entry(currentMessage, isFinal: true),
        ],
        canLoadEarlier: false
      )
    )

    await model.start()

    XCTAssertEqual(model.entries.map(\.key), ["task-prior:user:1", "agent:1"])
    XCTAssertEqual(model.entries.count, 2)
  }
}

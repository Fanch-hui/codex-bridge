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
  func testPriorHistoryLoadsEarlierPagesSoTheFirstPromptRemainsVisible() async {
    let priorMessages = (1...254).map(makePagedPriorMessage)
    let currentMessage = IPCTaskConversationMessage(
      messageID: 255,
      key: "agent:current",
      role: "agent",
      content: "当前轮结果"
    )
    let client = PagedSessionHistoryClient(
      priorMessages: priorMessages,
      currentMessage: currentMessage
    )
    let model = TaskConversationModel(
      taskID: "task-current",
      priorTaskIDs: ["task-prior"],
      client: client,
      isTerminal: true
    )

    await model.start()

    XCTAssertEqual(model.entries.first?.key, "task-prior:user:first")
    XCTAssertEqual(model.entries.first?.content, "第一条指令")
    XCTAssertEqual(model.entries.count, 255)
    XCTAssertEqual(model.entries.last?.key, "agent:current")
  }

  func testLoadEarlierPagesAcrossPriorTasksPreservesCompleteHistory() async {
    let oldPriorMessages = makePagedMessages(count: 350)
    let latestPriorMessages = makePagedMessages(count: 250)
    let client = MultiPagedSessionHistoryClient(
      messages: [
        "task-old": oldPriorMessages,
        "task-prior": latestPriorMessages,
      ],
      currentMessage: IPCTaskConversationMessage(
        messageID: 1,
        key: "agent:current",
        role: "agent",
        content: "当前轮结果"
      )
    )
    let model = TaskConversationModel(
      taskID: "task-current",
      priorTaskIDs: ["task-old", "task-prior"],
      client: client,
      isTerminal: true
    )

    await model.start()
    XCTAssertTrue(model.canLoadEarlier)
    XCTAssertFalse(model.entries.contains { $0.key == "task-old:user:first" })

    await model.loadEarlier()
    await model.loadEarlier()

    XCTAssertEqual(model.entries.first?.key, "task-old:user:first")
    XCTAssertEqual(model.entries.count, 601)
    XCTAssertFalse(model.canLoadEarlier)
  }

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

private func makePagedPriorMessage(_ messageID: Int) -> IPCTaskConversationMessage {
  IPCTaskConversationMessage(
    messageID: Int64(messageID),
    key: messageID == 1 ? "user:first" : "agent:" + String(messageID),
    role: messageID == 1 ? "user" : "agent",
    content: messageID == 1 ? "第一条指令" : "过程 " + String(messageID)
  )
}

private func makePagedMessages(count: Int) -> [IPCTaskConversationMessage] {
  (1...count).map(makePagedPriorMessage)
}

private actor PagedSessionHistoryClient: BridgeTaskConversationClient {
  let priorMessages: [IPCTaskConversationMessage]
  let currentMessage: IPCTaskConversationMessage

  init(
    priorMessages: [IPCTaskConversationMessage],
    currentMessage: IPCTaskConversationMessage
  ) {
    self.priorMessages = priorMessages
    self.currentMessage = currentMessage
  }

  func taskConversation(_ request: IPCTaskConversationRequest) async throws
    -> IPCTaskConversationPage
  {
    if request.taskID == "task-current" {
      return IPCTaskConversationPage(taskID: request.taskID, messages: [currentMessage])
    }

    let end = request.beforeMessageID.map { Int($0) - 1 } ?? priorMessages.count
    let start = max(1, end - request.limit + 1)
    let messages = priorMessages[(start - 1)..<end]
    return IPCTaskConversationPage(taskID: request.taskID, messages: Array(messages))
  }

  func subscribeTaskConversation(
    taskID: String,
    limit _: Int
  ) async throws -> (IPCTaskConversationSubscription, AsyncStream<IPCTaskConversationPush>) {
    let page = IPCTaskConversationPage(taskID: taskID, messages: [currentMessage])
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

private actor MultiPagedSessionHistoryClient: BridgeTaskConversationClient {
  let messages: [String: [IPCTaskConversationMessage]]
  let currentMessage: IPCTaskConversationMessage

  init(
    messages: [String: [IPCTaskConversationMessage]],
    currentMessage: IPCTaskConversationMessage
  ) {
    self.messages = messages
    self.currentMessage = currentMessage
  }

  func taskConversation(_ request: IPCTaskConversationRequest) async throws
    -> IPCTaskConversationPage
  {
    if request.taskID == "task-current" {
      return IPCTaskConversationPage(taskID: request.taskID, messages: [currentMessage])
    }
    guard let allMessages = messages[request.taskID] else {
      return IPCTaskConversationPage(taskID: request.taskID, messages: [])
    }
    let end = request.beforeMessageID.map { Int($0) - 1 } ?? allMessages.count
    let start = max(1, end - request.limit + 1)
    return IPCTaskConversationPage(
      taskID: request.taskID,
      messages: Array(allMessages[(start - 1)..<end])
    )
  }

  func subscribeTaskConversation(
    taskID: String,
    limit _: Int
  ) async throws -> (IPCTaskConversationSubscription, AsyncStream<IPCTaskConversationPush>) {
    let page = IPCTaskConversationPage(taskID: taskID, messages: [currentMessage])
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

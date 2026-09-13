import BridgeDesktopUI
import BridgeIPC
import XCTest

@testable import BridgeServiceAppShell

@MainActor
final class DesktopConversationObservationTests: XCTestCase {
  func testConversationPushRefreshesPresentationWithoutOuterModelPolling() async throws {
    let client = TestBridgeServiceClient()
    let conversation = TaskConversationModel(taskID: "task-1", client: client)
    let observation = DesktopConversationObservation()
    var displayedText = ""
    observation.observe(conversation) {
      displayedText = conversation.entries.last?.content ?? ""
    }
    XCTAssertTrue(conversation.isLoading)
    await conversation.start()
    XCTAssertFalse(conversation.isLoading)
    await client.pushConversation(
      IPCTaskConversationPush(
        taskID: "task-1", key: "agent:reply", role: "agent", delta: nil,
        baseContentLength: 0, fullContent: "live reply", final: false
      ))
    for _ in 0..<100 where displayedText != "live reply" {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(displayedText, "live reply")
    observation.observe(nil) {}
    await client.pushConversation(
      IPCTaskConversationPush(
        taskID: "task-1", key: "agent:reply", role: "agent", delta: nil,
        baseContentLength: 0, fullContent: "detached reply", final: true
      ))
    for _ in 0..<100 where conversation.entries.last?.content != "detached reply" {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(conversation.entries.last?.content, "detached reply")
    XCTAssertEqual(displayedText, "live reply")
    conversation.cancel()
  }
}

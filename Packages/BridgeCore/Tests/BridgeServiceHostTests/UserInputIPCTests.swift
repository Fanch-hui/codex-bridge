import BridgeIPC
import Foundation
import XCTest

final class UserInputIPCTests: XCTestCase {
  func testQuestionAndAnswersRoundTrip() throws {
    let question = IPCUserInputQuestion(
      id: "direction", header: "方案", question: "选择实现方式", isOther: true, isSecret: false,
      options: [.init(label: "方案一", description: "保持现有布局")]
    )
    let summary = IPCApprovalSummary(
      approvalID: "input-1", taskID: "task-1", threadID: "thread-1", turnID: "turn-1",
      itemID: "item-1", kind: "user_input", title: "Codex 需要你的回答", summary: "请选择",
      questions: [question]
    )
    XCTAssertEqual(
      try JSONDecoder().decode(IPCApprovalSummary.self, from: JSONEncoder().encode(summary)),
      summary)
    let answer = IPCApprovalResolutionRequest(
      taskID: "task-1", approvalID: "input-1", decision: "allow",
      answers: ["direction": ["方案一"]]
    )
    XCTAssertEqual(
      try JSONDecoder().decode(
        IPCApprovalResolutionRequest.self, from: JSONEncoder().encode(answer)), answer)
  }

  func testOlderApprovalPayloadsRemainCompatible() throws {
    let summary = Data(
      #"{"approval_id":"a","task_id":"t","thread_id":"th","turn_id":"tu","item_id":"i","kind":"command","title":"Run","summary":"Run","relative_paths":[]}"#
        .utf8)
    XCTAssertNil(try JSONDecoder().decode(IPCApprovalSummary.self, from: summary).questions)
    let request = Data(#"{"approval_id":"a","task_id":"t","decision":"allow"}"#.utf8)
    XCTAssertNil(try JSONDecoder().decode(IPCApprovalResolutionRequest.self, from: request).answers)
  }
}

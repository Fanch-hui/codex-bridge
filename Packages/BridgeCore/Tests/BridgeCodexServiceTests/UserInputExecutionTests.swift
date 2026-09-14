import BridgeCodexService
import BridgeDomain
import BridgeServiceCore
import Foundation
import XCTest

final class UserInputExecutionTests: XCTestCase {
  func testAnswerResumesOriginalTurnAndCannotBeReused() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(fixture: fixture, taskID: "question-answer")
    let manager = makeExecutionManager(script: questionScript(root: fixture.root.path))
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks, projects: fixture.projects, execution: manager)
    addTeardownBlock { await coordinator.shutdown() }
    _ = try await coordinator.start(taskID: task.id)
    let question = try await waitForApproval(coordinator, taskID: task.id)
    XCTAssertEqual(question.kind, .userInput)
    XCTAssertEqual(question.questions.first?.id, "choice")
    _ = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .waitingForCodexApproval
    }
    try await coordinator.resolveApproval(
      taskID: task.id, approvalID: question.id, decision: .allow, answers: ["choice": ["A"]])
    let completed = try await waitForTask(fixture, taskID: task.id) { $0.state.status.isTerminal }
    XCTAssertEqual(completed.state.status, .completed)
    XCTAssertEqual(completed.state.resultSummary, "Answer received.")
    do {
      try await coordinator.resolveApproval(
        taskID: task.id, approvalID: question.id, decision: .allow, answers: ["choice": ["A"]])
      XCTFail("Resolved question was accepted twice")
    } catch {}
  }

  func testStopInvalidatesPendingQuestion() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(fixture: fixture, taskID: "question-stop")
    let manager = makeExecutionManager(script: questionScript(root: fixture.root.path))
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks, projects: fixture.projects, execution: manager)
    addTeardownBlock { await coordinator.shutdown() }
    _ = try await coordinator.start(taskID: task.id)
    let question = try await waitForApproval(coordinator, taskID: task.id)
    await coordinator.stop(taskID: task.id)
    let pending = await coordinator.pendingApprovals(taskID: task.id)
    XCTAssertTrue(pending.isEmpty)
    do {
      try await coordinator.resolveApproval(
        taskID: task.id, approvalID: question.id, decision: .allow, answers: ["choice": ["A"]])
      XCTFail("Stopped question was accepted")
    } catch {}
  }

  func testNonblockingQuestionDoesNotPreventCompletion() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(fixture: fixture, taskID: "question-optional")
    let manager = makeExecutionManager(
      script: questionScript(root: fixture.root.path, blocking: false))
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks, projects: fixture.projects, execution: manager)
    addTeardownBlock { await coordinator.shutdown() }
    _ = try await coordinator.start(taskID: task.id)
    let completed = try await waitForTask(fixture, taskID: task.id) { $0.state.status.isTerminal }
    XCTAssertEqual(completed.state.status, .completed)
    let pending = await coordinator.pendingApprovals(taskID: task.id)
    XCTAssertTrue(pending.isEmpty)
  }

  private func questionScript(root: String, blocking: Bool = true) -> String {
    let script = commandApprovalScript(
      root: root, expectedDecision: "accept", finalMessage: "Answer received.")
    return script.components(separatedBy: "\n").compactMap { line -> String? in
      if line.contains("item/started") { return nil }
      if line.contains("item/commandExecution/requestApproval") {
        return
          #"printf '%s\n' '{"id":"approval-command","method":"item/tool/requestUserInput","params":{"threadId":"thread-approval","turnId":"turn-approval","itemId":"question-1","isBlocking":BLOCKING,"questions":[{"id":"choice","header":"Choice","question":"Choose a direction","isOther":true,"options":[{"label":"A","description":"First direction"}]}]}}'"#
          .replacingOccurrences(of: "BLOCKING", with: blocking ? "true" : "false")
      }
      if !blocking && (line.contains("read -r approval") || line.contains("case \"$approval\"")) {
        return nil
      }
      if line.contains("case \"$approval\"") && line.contains("decision") {
        return #"case "$approval" in *'"choice":{"answers":["A"]}'*) ;; *) exit 32 ;; esac"#
      }
      return line
    }.joined(separator: "\n")
  }
}

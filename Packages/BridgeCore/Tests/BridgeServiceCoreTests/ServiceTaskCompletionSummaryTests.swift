import BridgeDomain
import XCTest

@testable import BridgeServiceCore

final class ServiceTaskCompletionSummaryTests: XCTestCase {
  func testLongFinalResponseCompletesWithFullSummaryAndConversation() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let store = try SimpleServiceStore(path: fixture.databasePath)
    let project = try makeServiceProject(id: "prj-long-final", rootURL: fixture.firstProjectURL)
    try await store.insertProject(project)
    let task = try makeServiceTask(
      id: "tsk-long-final", projectID: project.id, status: .running)
    _ = try await store.createTask(task, event: creationEvent(at: task.createdAt))
    let response = String(repeating: "任务已完成 👩🏽‍💻。\n", count: 20_000)
    _ = try await store.upsertTaskMessage(
      ServiceTaskMessageDraft(
        key: "agent:final", role: .agent, content: response, createdAt: task.createdAt),
      taskID: task.id
    )
    let manager = ServiceTaskManager(
      store: store, now: { task.createdAt.addingTimeInterval(1) })
    let completed = try await manager.complete(
      taskID: task.id, resultSummary: response, changedFiles: [])
    XCTAssertEqual(completed.state.status, .completed)
    XCTAssertNil(completed.state.failureCode)
    let summary = try XCTUnwrap(completed.state.resultSummary)
    XCTAssertEqual(summary, response)
    let messages = try await store.taskMessages(taskID: task.id, limit: 10)
    XCTAssertEqual(messages.first?.content, response)
    let events = try await store.events(taskID: task.id)
    XCTAssertEqual(events.last?.kind, .taskCompleted)
  }

}

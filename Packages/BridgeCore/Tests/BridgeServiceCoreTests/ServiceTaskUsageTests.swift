import BridgeAgentCore
import BridgeDomain
import Foundation
import XCTest

@testable import BridgeServiceCore

final class ServiceTaskUsageTests: XCTestCase {
  func testUsageSnapshotSurvivesRestartWithoutAddingCumulativeCounts() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let store = try SimpleServiceStore(path: fixture.databasePath)
    let project = try makeServiceProject(id: "usage-project", rootURL: fixture.firstProjectURL)
    try await store.insertProject(project)
    let task = try makeServiceTask(id: "usage-task", projectID: project.id)
    _ = try await store.createTask(task, event: creationEvent(at: task.createdAt))
    let usage = try AgentUsageStatistics(
      inputTokens: 12_000, outputTokens: 300, totalTokens: 12_300,
      contextTokens: 2_000, contextWindow: 8_000, costAmount: 0.01, contextUsedPercentage: 25
    )
    try await store.setTaskUsage(usage, taskID: task.id)
    try await store.setTaskUsage(usage, taskID: task.id)
    let reopened = try SimpleServiceStore(path: fixture.databasePath)
    let saved = try await reopened.taskUsage(taskID: task.id)
    XCTAssertEqual(saved, usage)
    XCTAssertNil(saved?.currency)
    XCTAssertNil(saved?.cacheReadTokens)
    let missing = try await reopened.taskUsage(taskID: TaskID(rawValue: "missing"))
    XCTAssertNil(missing)
  }
}

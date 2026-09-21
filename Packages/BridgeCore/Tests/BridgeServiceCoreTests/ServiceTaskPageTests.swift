import BridgeDomain
import BridgeServiceCore
import XCTest

final class ServiceTaskPageTests: XCTestCase {
  func testPagesKeepTiedTimestampsWithoutRepeatingTasks() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let store = try SimpleServiceStore(path: fixture.databasePath)
    let project = try makeServiceProject(id: "prj-page", rootURL: fixture.firstProjectURL)
    try await store.insertProject(project)
    let date = Date(timeIntervalSince1970: 1_800_001_000)
    for id in ["tsk-a", "tsk-b", "tsk-c"] {
      let task = try makeServiceTask(
        id: id, projectID: project.id, date: date, permissionMode: .readOnly)
      _ = try await store.createTask(task, event: creationEvent(at: date))
    }
    let first = try await store.taskPage(
      projectID: project.id, beforeDate: nil, beforeID: nil, limit: 2)
    let second = try await store.taskPage(
      projectID: project.id, beforeDate: date, beforeID: first.last?.id.rawValue, limit: 2)
    XCTAssertEqual(first.map(\.id.rawValue), ["tsk-a", "tsk-b"])
    XCTAssertEqual(second.map(\.id.rawValue), ["tsk-c"])
  }
}

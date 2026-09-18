import BridgeDomain
import BridgeProjects
import BridgeServiceCore
import XCTest

final class ServiceReviewRegressionTests: XCTestCase {
  func testClientPermissionsPersistIndependentlyFromTaskMode() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let settings = ServiceSettings(store: try SimpleServiceStore(path: fixture.databasePath))
    try await settings.setExposureMode(.readOnly)
    try await settings.setQwenStudioExposureMode(.full)
    try await settings.setWorkbenchPermissionMode(.readOnly)
    try await settings.setQwenStudioExposureMode(.readOnly)
    try await settings.setWorkbenchPermissionMode(.workspaceWrite)
    let reopened = ServiceSettings(store: try SimpleServiceStore(path: fixture.databasePath))
    let chat = try await reopened.exposureMode()
    let qwen = try await reopened.qwenStudioExposureMode()
    let task = try await reopened.workbenchPermissionMode()
    XCTAssertEqual(chat, .readOnly)
    XCTAssertEqual(qwen, .readOnly)
    XCTAssertEqual(task, .workspaceWrite)
    try await reopened.setExposureMode(.full)
    let unchangedQwen = try await reopened.qwenStudioExposureMode()
    let unchangedTask = try await reopened.workbenchPermissionMode()
    XCTAssertEqual(unchangedQwen, .readOnly)
    XCTAssertEqual(unchangedTask, .workspaceWrite)
  }

  func testConcurrentProjectEditsPreserveBothFields() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let store = try SimpleServiceStore(path: fixture.databasePath)
    let service = ServiceProjectService(store: store)
    let project = try await service.register(name: "Project", rootURL: fixture.firstProjectURL)
    let command = try ServiceWorkspaceCommand(
      id: "test", name: "Test", executable: "git", arguments: ["status"])
    let policy = ProjectAccessPolicy(read: .allowed, write: .denied, network: .denied)
    async let permission = service.updateAccessPolicy(policy, projectID: project.id)
    async let workspace = service.updateWorkspaceCommands(
      [command], commandBlacklist: [], projectID: project.id)
    _ = try await (permission, workspace)
    let saved = try await store.project(id: project.id)
    XCTAssertEqual(saved?.accessPolicy, policy)
    XCTAssertEqual(saved?.workspaceCommands, [command])
  }

  func testTaskListActivityMatchesIndividualQueries() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let store = try SimpleServiceStore(path: fixture.databasePath)
    let project = try makeServiceProject(id: "prj-activity", rootURL: fixture.firstProjectURL)
    try await store.insertProject(project)
    var ids: [TaskID] = []
    for index in 0..<2 {
      let task = try makeServiceTask(
        id: "tsk-activity-\(index)", projectID: project.id, permissionMode: .readOnly)
      _ = try await store.createTask(task, event: creationEvent(at: task.createdAt))
      ids.append(task.id)
      for message in 0..<10 {
        _ = try await store.upsertTaskMessage(
          ServiceTaskMessageDraft(
            key: "message-\(message)", role: .agent, content: "Message \(message)",
            createdAt: task.createdAt.addingTimeInterval(Double(message))), taskID: task.id)
      }
    }
    let batch = try await store.taskListActivity(taskIDs: ids)
    XCTAssertTrue(batch.messagesAvailable)
    for id in ids {
      let events = try await store.events(taskID: id, limit: 6)
      let messages = try await store.recentTaskMessageActivity(taskID: id, limit: 8)
      XCTAssertEqual(batch.events[id], events)
      XCTAssertEqual(batch.messages[id], messages)
    }
  }
}

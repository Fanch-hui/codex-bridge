import BridgeDomain
import Foundation
import GRDB
import XCTest

@testable import BridgeServiceCore

final class ServiceTaskQueueTests: XCTestCase {
  func testQueuedWritePersistsPromotesAfterCompletionAndCanBeCancelled() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let store = try SimpleServiceStore(path: fixture.databasePath)
    let project = try makeServiceProject(
      id: "prj-task-queue",
      rootURL: fixture.firstProjectURL
    )
    try await store.insertProject(project)
    let clock = ServiceCoreTestClock()
    let tasks = ServiceTaskManager(
      store: store,
      makeTaskID: {
        TaskID(rawValue: "tsk-queue-\(UUID().uuidString.lowercased())")
      },
      now: clock.next
    )

    let active = try await tasks.submit(
      ServiceTaskRequest(
        projectID: project.id,
        source: .macOSApp,
        prompt: "Run the active task.",
        executionModel: "codex-model",
        executionEffort: "high",
        permissionMode: .workspaceWrite
      )
    )
    _ = try await tasks.begin(taskID: active.task.id)
    _ = try await tasks.markExecutionStarted(
      taskID: active.task.id,
      threadID: "thread-active",
      turnID: "turn-active"
    )

    let queued = try await tasks.submit(
      ServiceTaskRequest(
        projectID: project.id,
        source: .macOSApp,
        prompt: "Run the queued task.",
        executionModel: "codex-model",
        executionEffort: "high",
        permissionMode: .workspaceWrite,
        queueIfBusy: true
      ),
      queued: true
    )
    let queuedInfo = try await tasks.queueInfo(taskID: queued.task.id)
    XCTAssertEqual(queuedInfo?.position, 1)
    XCTAssertEqual(queuedInfo?.occupyingTaskID, active.task.id)

    let reopened = try SimpleServiceStore(path: fixture.databasePath)
    let persistedQueue = try await reopened.queuedTasks()
    XCTAssertEqual(persistedQueue.map(\.id), [queued.task.id])

    _ = try await tasks.complete(
      taskID: active.task.id,
      resultSummary: "The active task completed.",
      changedFiles: []
    )
    let promoted = try await tasks.promoteQueued(taskID: queued.task.id)
    XCTAssertEqual(promoted?.id, queued.task.id)
    XCTAssertEqual(promoted?.isQueued, false)
    let promotedQueueInfo = try await tasks.queueInfo(taskID: queued.task.id)
    XCTAssertNil(promotedQueueInfo)
    let activeAfterPromotion = try await tasks.activeWriteTask(projectID: project.id)
    XCTAssertEqual(activeAfterPromotion?.id, queued.task.id)

    let secondQueued = try await tasks.submit(
      ServiceTaskRequest(
        projectID: project.id,
        source: .macOSApp,
        prompt: "Cancel this queued task.",
        executionModel: "codex-model",
        executionEffort: "high",
        permissionMode: .workspaceWrite,
        queueIfBusy: true
      ),
      queued: true
    )
    let cancelled = try await tasks.interrupt(
      taskID: secondQueued.task.id,
      summary: "The queued task was cancelled."
    )
    XCTAssertEqual(cancelled.state.status, .interrupted)
    let remainingQueue = try await tasks.queuedTasks()
    XCTAssertTrue(remainingQueue.isEmpty)
  }

  func testVersionSixteenDataSurvivesQueueMigration() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let legacy = try DatabaseQueue(path: fixture.databasePath)
    try await legacy.writeWithoutTransaction { db in
      try db.execute(
        sql: "CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY NOT NULL)"
      )
      func apply(_ version: Int, _ migration: () throws -> Void) throws {
        try migration()
        try db.execute(
          sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
          arguments: ["BridgeServiceCore.v\(version)"]
        )
      }
      try apply(1) { try ServiceStoreSchema.createVersionOne(in: db) }
      try apply(2) { try ServiceStoreSchema.createVersionTwo(in: db) }
      try apply(3) { try ServiceStoreSchema.createVersionThree(in: db) }
      try apply(4) { try ServiceStoreSchema.createVersionFour(in: db) }
      try apply(5) { try ServiceStoreSchema.createVersionFive(in: db) }
      try apply(6) { try ServiceStoreSchema.createVersionSix(in: db) }
      try apply(7) { try ServiceStoreSchema.createVersionSeven(in: db) }
      try apply(8) { try ServiceStoreSchema.createVersionEight(in: db) }
      try apply(9) { try ServiceStoreSchema.createVersionNine(in: db) }
      try apply(10) { try ServiceStoreSchema.createVersionTen(in: db) }
      try apply(11) { try ServiceStoreSchema.createVersionEleven(in: db) }
      try apply(12) { try ServiceStoreSchema.createVersionTwelve(in: db) }
      try apply(13) { try ServiceStoreSchema.createVersionThirteen(in: db) }
      try apply(14) { try ServiceStoreSchema.createVersionFourteen(in: db) }
      try apply(15) { try ServiceStoreSchema.createVersionFifteen(in: db) }
      try apply(16) { try ServiceStoreSchema.createVersionSixteen(in: db) }

      let project = try makeServiceProject(
        id: "prj-v16-queue",
        rootURL: fixture.firstProjectURL
      )
      try db.execute(
        sql: """
          INSERT INTO bridge_service_projects (
            project_id, name, canonical_path, root_device, root_inode, root_volume_uuid,
            read_permission, write_permission, network_permission, created_at, updated_at,
            direct_command_mode, workspace_commands_json, direct_blacklist_json
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          project.id.rawValue, project.name, project.root.canonicalPath,
          String(project.root.device), String(project.root.inode), project.root.volumeUUID,
          project.accessPolicy.read.rawValue, project.accessPolicy.write.rawValue,
          project.accessPolicy.network.rawValue, project.createdAt.timeIntervalSince1970,
          project.updatedAt.timeIntervalSince1970, project.directCommandMode.rawValue,
          Data("[]".utf8), Data("[]".utf8),
        ]
      )
      try db.execute(
        sql: """
          INSERT INTO bridge_service_tasks (
            task_id, project_id, source, source_client_id, client_request_id, prompt,
            requested_thread_id, codex_thread_id, codex_turn_id, status, supervisor_status,
            execution_model, execution_effort, supervisor_model, supervisor_effort,
            permission_mode, network_allowed, access_mode, fast_mode, current_step,
            changed_files_json, result_summary, supervisor_summary, failure_code,
            created_at, updated_at, provider_id, installation_id, selection_mode,
            provider_session_id, provider_run_id
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          "tsk-v16-preserved", project.id.rawValue, "macos.app", "", nil,
          "Legacy task that must survive the queue migration.", nil, nil, nil, "completed",
          "disabled", "codex-model", "high", nil, nil, "workspace-write", 0,
          "request-approval", 0, nil, Data("[]".utf8), "Legacy result", nil, nil,
          1_800_000_100, 1_800_000_100, "codex", nil, "legacy_codex", nil, nil,
        ]
      )
      try db.execute(
        sql: """
          INSERT INTO bridge_service_task_events (task_id, kind, summary, created_at)
          VALUES (?, 'task.created', ?, ?)
          """,
        arguments: [
          "tsk-v16-preserved", "The legacy task was created.", 1_800_000_100,
        ]
      )
    }

    let store = try SimpleServiceStore(path: fixture.databasePath)
    let preserved = try await store.task(id: TaskID(rawValue: "tsk-v16-preserved"))
    XCTAssertEqual(preserved?.state.status, .completed)
    XCTAssertEqual(preserved?.state.resultSummary, "Legacy result")
    let preservedEvents = try await store.events(taskID: TaskID(rawValue: "tsk-v16-preserved"))
    XCTAssertEqual(preservedEvents.count, 1)

    let manager = ServiceTaskManager(store: store)
    let queued = try await manager.submit(
      ServiceTaskRequest(
        projectID: ProjectID(rawValue: "prj-v16-queue"),
        source: .macOSApp,
        prompt: "Queue a task after upgrading the old database.",
        executionModel: "codex-model",
        executionEffort: "high",
        permissionMode: .workspaceWrite,
        queueIfBusy: true
      ),
      queued: true
    )
    XCTAssertEqual(queued.task.isQueued, true)
    let migratedQueue = try await store.queuedTasks()
    XCTAssertEqual(migratedQueue.map(\.id), [queued.task.id])
  }
}

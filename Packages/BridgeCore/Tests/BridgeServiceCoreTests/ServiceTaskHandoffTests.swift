import BridgeDomain
import Foundation
import GRDB
import XCTest

@testable import BridgeServiceCore

final class ServiceTaskHandoffTests: XCTestCase {
  private func setup() async throws -> (ServiceCoreFixture, SimpleServiceStore, ServiceTaskRecord) {
    let fixture = try ServiceCoreFixture()
    let store = try SimpleServiceStore(path: fixture.databasePath)
    let project = try makeServiceProject(id: "project-handoff", rootURL: fixture.firstProjectURL)
    try await store.insertProject(project)
    let source = try makeServiceTask(
      id: "source-handoff", projectID: project.id, source: .macOSApp,
      prompt: "Keep the original Mac API unchanged.", status: .completed, permissionMode: .readOnly)
    _ = try await store.createTask(source, event: creationEvent(at: source.createdAt))
    return (fixture, store, source)
  }

  private func prepare(
    _ store: SimpleServiceStore, source: ServiceTaskRecord, id: String = "handoff-test",
    providerID: String = "opencode", addition: String = ""
  ) async throws -> ServiceTaskHandoffRecord {
    let packet = try await store.handoffPacket(taskID: source.id)
    let rendered = TaskHandoffRenderer.render(
      packet, handoffID: id, additionalInstructions: addition)
    XCTAssertTrue(rendered.ready)
    let preview = TaskHandoffPreview(
      handoffID: id, sourceTaskID: source.id.rawValue, providerID: providerID, model: "codex-model",
      permissionMode: "read-only", networkAllowed: false, revision: "test-revision",
      prompt: rendered.prompt, additionalInstructions: addition, warnings: rendered.warnings,
      ready: rendered.ready, estimatedTokens: rendered.estimatedTokens)
    let record = ServiceTaskHandoffRecord(
      packet: packet, preview: preview, targetFingerprint: String(repeating: "a", count: 64))
    try await store.saveHandoff(record)
    return record
  }

  private func target(
    _ record: ServiceTaskHandoffRecord, id: String = "target-handoff", prompt: String? = nil
  ) throws -> ServiceTaskRecord {
    try makeServiceTask(
      id: id, projectID: ProjectID(rawValue: record.packet.projectID),
      date: Date(timeIntervalSince1970: 1_800_000_500), source: .macOSApp,
      clientRequestID: "handoff:" + record.preview.handoffID,
      prompt: prompt ?? record.preview.prompt, providerID: record.preview.providerID,
      selectionMode: .explicit, status: .completed, permissionMode: .readOnly)
  }

  private func message(
    _ store: SimpleServiceStore, taskID: TaskID, key: String, text: String,
    role: ServiceTaskMessageRole = .user
  ) async throws {
    _ = try await store.upsertTaskMessage(
      ServiceTaskMessageDraft(
        key: key, role: role, content: text,
        createdAt: Date(timeIntervalSince1970: 1_800_001_000)), taskID: taskID)
  }

  func testSteersAreIncludedAndChangeTheSourceRevision() async throws {
    let (fixture, store, source) = try await setup()
    defer { fixture.remove() }
    let before = try await store.handoffPacket(taskID: source.id)
    try await message(store, taskID: source.id, key: "initial", text: source.prompt)
    try await message(store, taskID: source.id, key: "steer-one", text: "Do not edit AGENTS.md.")
    let after = try await store.handoffPacket(taskID: source.id)
    XCTAssertEqual(after.requirements.count, 2)
    XCTAssertTrue(after.requirements.contains { $0.text == "Do not edit AGENTS.md." })
    XCTAssertNotEqual(before.sourceRevision, after.sourceRevision)
  }

  func testSessionUsesCreationOrderNotLastUpdatedOrderAndKeepsAllTurns() async throws {
    let (fixture, store, original) = try await setup()
    defer { fixture.remove() }
    var turns: [ServiceTaskRecord] = []
    for index in 0..<18 {
      let turn = try makeServiceTask(
        id: "session-turn-\(index)", projectID: original.projectID,
        date: Date(timeIntervalSince1970: 1_800_000_100 + Double(index)),
        source: .macOSApp, prompt: "Constraint from turn \(index)", providerID: "opencode",
        selectionMode: .explicit, status: .completed, providerSessionID: "shared-session",
        providerRunID: "run-\(index)", permissionMode: .readOnly)
      _ = try await store.createTask(turn, event: creationEvent(at: turn.createdAt))
      turns.append(turn)
    }
    try await message(
      store, taskID: turns[0].id, key: "late-steer", text: "An early task was updated later.")
    let packet = try await store.handoffPacket(taskID: turns[17].id)
    XCTAssertEqual(packet.requirements.first?.text, "Constraint from turn 0")
    for index in 0..<18 {
      XCTAssertTrue(packet.requirements.contains { $0.text == "Constraint from turn \(index)" })
    }
    do {
      _ = try await store.handoffPacket(taskID: turns[0].id)
      XCTFail("A non-latest source must be rejected")
    } catch is TaskHandoffError {}
  }

  func testFrozenPreviewRejectsStaleSourceInsideTaskCreationTransaction() async throws {
    let (fixture, store, source) = try await setup()
    defer { fixture.remove() }
    let record = try await prepare(store, source: source)
    try await message(store, taskID: source.id, key: "late", text: "New constraint after preview.")
    let requested = try target(record)
    do {
      _ = try await store.createTask(
        requested, event: creationEvent(at: requested.createdAt),
        handoffID: record.preview.handoffID)
      XCTFail("A stale packet must not create a target")
    } catch is TaskHandoffError {}
    let target = try await store.task(id: requested.id)
    let persisted = try await store.handoff(id: record.preview.handoffID)
    XCTAssertNil(target)
    XCTAssertNil(persisted?.targetTaskID)
  }

  func testAtomicIdempotencySurvivesReopenAndDeletedTargetCannotReplay() async throws {
    let (fixture, store, source) = try await setup()
    defer { fixture.remove() }
    let record = try await prepare(store, source: source)
    let requested = try target(record)
    let first = try await store.createTask(
      requested, event: creationEvent(at: requested.createdAt),
      handoffID: record.preview.handoffID)
    let reopened = try SimpleServiceStore(path: fixture.databasePath)
    let second = try await reopened.createTask(
      requested, event: creationEvent(at: requested.createdAt),
      handoffID: record.preview.handoffID)
    XCTAssertEqual(first.task.id, second.task.id)
    XCTAssertTrue(second.reusedExistingTask)
    let manager = ServiceTaskManager(store: reopened)
    try await manager.remove(taskID: requested.id)
    let tombstone = try await reopened.handoff(id: record.preview.handoffID)
    XCTAssertEqual(tombstone?.targetTaskID, requested.id.rawValue)
    do {
      _ = try await reopened.createTask(
        requested, event: creationEvent(at: requested.createdAt),
        handoffID: record.preview.handoffID)
      XCTFail("Deleting a target must not allow duplicate execution")
    } catch is TaskHandoffError {}
  }

  func testRepeatedHandoffFlattensRequirementsAndPreservesSupplementOnce() async throws {
    let (fixture, store, source) = try await setup()
    defer { fixture.remove() }
    let first = try await prepare(store, source: source, addition: "Verify Windows as well.")
    let middle = try target(first)
    _ = try await store.createTask(
      middle, event: creationEvent(at: middle.createdAt),
      handoffID: first.preview.handoffID)
    try await message(store, taskID: middle.id, key: "initial", text: middle.prompt)
    try await message(store, taskID: middle.id, key: "steer", text: "Keep the read-only boundary.")
    let second = try await prepare(store, source: middle, id: "handoff-next", providerID: "codex")
    XCTAssertEqual(second.packet.requirements.filter { $0.text == source.prompt }.count, 1)
    XCTAssertEqual(
      second.packet.requirements.filter { $0.text == "Verify Windows as well." }.count, 1)
    XCTAssertTrue(second.packet.requirements.contains { $0.text == "Keep the read-only boundary." })
    XCTAssertFalse(second.packet.requirements.contains { $0.text.contains("交接协议 v1") })
  }

  func testWrongPromptCannotBindAndUserEchoIsNotAgentAcknowledgement() async throws {
    let (fixture, store, source) = try await setup()
    defer { fixture.remove() }
    let record = try await prepare(store, source: source)
    let modified = try target(record, prompt: "Substitute a different task.")
    do {
      _ = try await store.createTask(
        modified, event: creationEvent(at: modified.createdAt),
        handoffID: record.preview.handoffID)
      XCTFail("Modified text must not pass the frozen preview contract")
    } catch is TaskHandoffError {}
    let requested = try target(record)
    _ = try await store.createTask(
      requested, event: creationEvent(at: requested.createdAt),
      handoffID: record.preview.handoffID)
    let ack = "HANDOFF-ACK: " + record.preview.handoffID
    try await message(store, taskID: requested.id, key: "user-echo", text: ack)
    let userOnly = try await store.handoffAcknowledged(
      taskID: requested.id, handoffID: record.preview.handoffID)
    XCTAssertFalse(userOnly)
    try await message(
      store, taskID: requested.id, key: "agent-ack", text: ack + "\nNext steps.", role: .agent)
    let confirmed = try await store.handoffAcknowledged(
      taskID: requested.id, handoffID: record.preview.handoffID)
    XCTAssertTrue(confirmed)
  }

  func testVersionSeventeenMigrationPreservesExistingTasks() async throws {
    let (fixture, store, source) = try await setup()
    defer { fixture.remove() }
    let legacy = try DatabaseQueue(path: fixture.databasePath)
    try await legacy.write { db in
      try db.execute(sql: "DROP TABLE bridge_service_handoffs")
      try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'BridgeServiceCore.v18'")
      try db.execute(sql: "UPDATE bridge_service_meta SET schema_version = 17 WHERE singleton = 1")
    }
    let migrated = try SimpleServiceStore(path: fixture.databasePath)
    let preserved = try await migrated.task(id: source.id)
    XCTAssertEqual(preserved?.prompt, source.prompt)
    _ = try await prepare(migrated, source: source)
    _ = store
  }
}

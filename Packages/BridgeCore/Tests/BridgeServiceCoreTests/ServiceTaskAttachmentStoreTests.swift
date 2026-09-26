import BridgeAgentCore
import BridgeDomain
import Foundation
import XCTest

@testable import BridgeServiceCore

final class ServiceTaskAttachmentStoreTests: XCTestCase {
  func testTaskAttachmentMetadataSurvivesRestartAndRejectsChangedIdempotentInput() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let store = try SimpleServiceStore(path: fixture.databasePath)
    let project = try makeServiceProject(id: "image-project", rootURL: fixture.firstProjectURL)
    try await store.insertProject(project)
    let task = try makeServiceTask(id: "image-task", projectID: project.id)
    let attachment = try AgentImageAttachment(
      relativePath: "assets/diagram.png",
      mimeType: "image/png",
      byteCount: 16,
      sha256: String(repeating: "a", count: 64)
    )
    _ = try await store.createTask(
      task,
      event: creationEvent(at: task.createdAt),
      attachments: [attachment]
    )

    let reopened = try SimpleServiceStore(path: fixture.databasePath)
    let persisted = try await reopened.taskAttachments(taskID: task.id)
    XCTAssertEqual(persisted, [attachment])
    let batched = try await reopened.taskAttachments(taskIDs: [task.id])
    XCTAssertEqual(batched[task.id], [attachment])

    let changed = try AgentImageAttachment(
      relativePath: "assets/diagram.png",
      mimeType: "image/png",
      byteCount: 16,
      sha256: String(repeating: "b", count: 64)
    )
    do {
      _ = try await reopened.createTask(
        task,
        event: creationEvent(at: task.createdAt),
        attachments: [changed]
      )
      XCTFail("Expected changed attachment metadata to reject task reuse")
    } catch {
      XCTAssertEqual(error as? ServiceStoreError, .invalidArgument("task.attachments"))
    }
  }
}

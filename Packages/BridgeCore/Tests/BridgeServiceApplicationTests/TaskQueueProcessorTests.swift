import BridgeDomain
import BridgeServiceApplication
import BridgeServiceCore
import Foundation
import XCTest

final class TaskQueueProcessorTests: XCTestCase {
  func testCatalogFailureLeavesExplicitlySelectedQueuedTaskQueued() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let modelRequestMarker = fixture.root.appending(path: "model-list-requested")
    let catalogScript = #"""
      IFS= read -r initialize
      printf '%s\n' '{"id":1,"result":{"userAgent":"fixture/1","codexHome":"/private/fixture","platformFamily":"unix","platformOs":"macos"}}'
      IFS= read -r initialized
      IFS= read -r request
      case "$request" in *'"method":"model/list"'*) ;; *) exit 11 ;; esac
      printf 'requested\n' > "\#(modelRequestMarker.path)"
      printf '%s\n' '{"id":2,"error":{"code":-32601,"message":"model catalog unavailable"}}'
      sleep 1
      """#
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: catalogScript
    )
    addTeardownBlock { await application.shutdownTaskQueueProcessor() }

    let taskID = TaskID(rawValue: "tsk-queued-catalog-unavailable")
    _ = try await fixture.tasks.submit(
      ServiceTaskRequest(
        projectID: fixture.project.id,
        source: .mcpClient,
        sourceClientID: "chatgpt",
        clientRequestID: "queued-catalog-unavailable",
        prompt: "Continue after the current task.",
        executionModel: "execution-model",
        executionEffort: serviceDefaultProviderExecutionEffort,
        permissionMode: .workspaceWrite
      ),
      taskID: taskID,
      queued: true
    )

    await application.startTaskQueueProcessor()
    let probeDeadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: modelRequestMarker.path),
      Date() < probeDeadline
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: modelRequestMarker.path))
    try await Task.sleep(for: .milliseconds(150))

    let queuedTask = try await fixture.tasks.task(id: taskID)
    XCTAssertEqual(queuedTask?.state.status, .awaitingLocalApproval)
    XCTAssertTrue(queuedTask?.isQueued == true)
    XCTAssertNil(queuedTask?.state.failureCode)
  }
}

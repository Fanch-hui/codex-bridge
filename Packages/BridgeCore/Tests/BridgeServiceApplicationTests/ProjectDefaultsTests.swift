import BridgeDomain
import BridgeMCP
import Foundation
import XCTest

@testable import BridgeServiceApplication

final class ProjectDefaultsTests: XCTestCase {
  func testProjectDirectoryAndSubmissionUseTheCurrentWorkbenchDefault() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let root = fixture.root.appending(path: "second-project", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let second = try await fixture.projects.register(
      name: "Second Project", rootURL: root, id: ProjectID(rawValue: "prj-default-second")
    )
    let application = makeServiceApplication(
      fixture: fixture, catalogScript: serviceModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    for projectID in [fixture.project.id.rawValue, second.id.rawValue] {
      try await application.serviceSetWorkbenchProjectID(projectID, deadline: deadline)
      let page = try await application.serviceProjects(cursor: nil, limit: 100, deadline: deadline)
      XCTAssertEqual(page.defaultProjectID, projectID)
      let encoded = try JSONEncoder().encode(ListProjectsOutput(page: page))
      let output = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
      XCTAssertEqual(output["default_project_id"] as? String, projectID)
    }
    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        prompt: "Use the current project.", clientRequestID: "default-project"),
      deadline: deadline
    )
    let stored = try await fixture.tasks.task(id: TaskID(rawValue: receipt.taskID))
    XCTAssertEqual(stored?.projectID, second.id)
  }
}

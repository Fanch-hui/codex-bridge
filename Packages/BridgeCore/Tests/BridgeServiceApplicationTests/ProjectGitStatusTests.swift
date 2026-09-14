import BridgeDirectCommand
import Foundation
import XCTest

@testable import BridgeServiceApplication

final class ProjectGitStatusTests: XCTestCase {
  func testProjectQueriesReflectWorkingTreeChanges() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let app = makeServiceApplication(fixture: fixture, catalogScript: "")
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    let initial = try await app.serviceManagedProjects(deadline: deadline)
    XCTAssertEqual(initial.first?.gitState, "not_git")

    let runner = DirectGitRunner()
    let initialized = try await runner.run(
      argv: [DirectGitRunner.gitPath, "init"], workingDirectory: fixture.root.path
    )
    XCTAssertEqual(initialized.exitCode, 0)
    try Data("service.sqlite*\n".utf8).write(
      to: fixture.root.appending(path: ".git/info/exclude")
    )
    let clean = try await app.serviceManagedProjects(deadline: deadline)
    XCTAssertEqual(clean.first?.gitState, "clean")
    let file = fixture.root.appending(path: "example.txt")
    try Data("example".utf8).write(to: file)
    let dirty = try await app.serviceProject(
      projectID: fixture.project.id.rawValue, deadline: deadline
    )
    XCTAssertEqual(dirty.gitState, "dirty")
    try FileManager.default.removeItem(at: file)
    let restored = try await app.serviceProjects(cursor: nil, limit: 10, deadline: deadline)
    XCTAssertEqual(restored.projects.first?.gitState, "clean")
  }
}

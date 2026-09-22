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
    // The project list caches git state for a few seconds, so transitions are
    // observed through the uncached single-project query.
    let clean = try await app.serviceProject(
      projectID: fixture.project.id.rawValue, deadline: deadline
    )
    XCTAssertEqual(clean.gitState, "clean")
    let file = fixture.root.appending(path: "example.txt")
    try Data("example".utf8).write(to: file)
    let dirty = try await app.serviceProject(
      projectID: fixture.project.id.rawValue, deadline: deadline
    )
    XCTAssertEqual(dirty.gitState, "dirty")
    try FileManager.default.removeItem(at: file)
    let restored = try await app.serviceProject(
      projectID: fixture.project.id.rawValue, deadline: deadline
    )
    XCTAssertEqual(restored.gitState, "clean")
  }

  func testProjectListReportsModifiedWorkingTree() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let runner = DirectGitRunner()
    let initialized = try await runner.run(
      argv: [DirectGitRunner.gitPath, "init"], workingDirectory: fixture.root.path
    )
    XCTAssertEqual(initialized.exitCode, 0)
    try Data("service.sqlite*\n".utf8).write(
      to: fixture.root.appending(path: ".git/info/exclude")
    )
    try Data("example".utf8).write(to: fixture.root.appending(path: "example.txt"))

    let app = makeServiceApplication(fixture: fixture, catalogScript: "")
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    let projects = try await app.serviceManagedProjects(deadline: deadline)
    XCTAssertEqual(projects.first?.gitState, "dirty")
  }

  func testPorcelainRecordDetectionReadsRawOutput() {
    XCTAssertTrue(
      ProjectGitStatus.hasPorcelainRecords(
        result(completeOutput: Data(" M example.txt".utf8) + Data([0]))
      )
    )
    XCTAssertFalse(
      ProjectGitStatus.hasPorcelainRecords(
        result(completeOutput: Data("warning: unexpected output\n".utf8))
      )
    )
  }

  func testPorcelainRecordDetectionFallsBackToEscapedOverflow() {
    XCTAssertTrue(
      ProjectGitStatus.hasPorcelainRecords(
        result(output: output(head: " M example.txt\\x00 M other.txt\\x00"))
      )
    )
    XCTAssertFalse(
      ProjectGitStatus.hasPorcelainRecords(
        result(output: output(head: "warning: unexpected output\n"))
      )
    )
  }

  private func output(head: String) -> DirectCommandOutputBuffer {
    DirectCommandOutputBuffer(head: head, tail: head, byteCount: head.utf8.count, truncated: true)
  }

  private func result(output: DirectCommandOutputBuffer) -> DirectGitResult {
    DirectGitResult(exitCode: 0, output: output, completeOutput: nil)
  }

  private func result(completeOutput: Data) -> DirectGitResult {
    DirectGitResult(
      exitCode: 0,
      output: DirectCommandOutputBuffer(
        head: "",
        tail: "",
        byteCount: completeOutput.count,
        truncated: false
      ),
      completeOutput: completeOutput
    )
  }
}

#if os(Windows)
  import BridgeDirectCommand
  import BridgeDomain
  import BridgeServiceApplication
  import BridgeServiceCore
  import Foundation
  import XCTest

  @testable import BridgeServiceApplication

  final class WindowsProjectGitStatusTests: XCTestCase {
    func testWorkingTreeChangesAreReportedThroughRealGit() async throws {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-windows-git-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }

      let store = try SimpleServiceStore.inMemory()
      let projects = ServiceProjectService(store: store)
      let project = try await projects.register(
        name: "Windows git project",
        rootURL: root,
        id: ProjectID(rawValue: "prj-windows-git")
      )
      let deadline = ContinuousClock.now.advanced(by: .seconds(30))

      let runner = DirectGitRunner()
      let initialized = try await runner.run(
        argv: [DirectGitRunner.gitPath, "init"],
        workingDirectory: root.path
      )
      XCTAssertEqual(initialized.exitCode, 0)
      try FileManager.default.createDirectory(
        at: root.appending(path: ".git/info"),
        withIntermediateDirectories: true
      )
      try Data("bridge.sqlite*\n".utf8).write(to: root.appending(path: ".git/info/exclude"))

      let clean = await ProjectGitStatus.read(project, deadline: deadline)
      XCTAssertEqual(clean, "clean")

      let file = root.appending(path: "example.txt")
      try Data("example".utf8).write(to: file)
      let dirty = await ProjectGitStatus.read(project, deadline: deadline)
      XCTAssertEqual(dirty, "dirty")

      try FileManager.default.removeItem(at: file)
      let restored = await ProjectGitStatus.read(project, deadline: deadline)
      XCTAssertEqual(restored, "clean")
    }
  }
#endif

#if os(Windows)
  import BridgeDomain
  import BridgeFiles
  import BridgeProjects
  import Foundation
  import XCTest

  final class WindowsProjectMutationTests: XCTestCase {
    func testWriteReplacePatchAndMoveHappyPath() async throws {
      let fixture = try await makeFixture()
      defer { fixture.remove() }

      let created = try await fixture.service.write(
        ProjectWriteRequest(
          projectID: fixture.projectID,
          relativePath: "nested/new.txt",
          mode: .create,
          content: "one\n",
          createParents: true
        )
      )
      guard let createdRevision = created.newSHA256 else {
        return XCTFail("create did not return a revision")
      }

      let replaced = try await fixture.service.write(
        ProjectWriteRequest(
          projectID: fixture.projectID,
          relativePath: "nested/new.txt",
          mode: .replace,
          content: "two\n",
          expectedSHA256: createdRevision
        )
      )
      XCTAssertEqual(
        try String(contentsOf: fixture.root.appending(path: "nested/new.txt"), encoding: .utf8),
        "two\n"
      )
      XCTAssertEqual(replaced.oldSHA256, createdRevision)

      let patch = """
        *** Begin Patch
        *** Update File: nested/new.txt
        @@
        -two
        +three
        *** Add File: nested/added.txt
        +added
        *** End Patch
        """
      let patchResults = try await fixture.service.applyPatch(
        ProjectApplyPatchRequest(
          projectID: fixture.projectID,
          operations: try ProjectPatchParser.parse(patch)
        )
      )
      XCTAssertEqual(patchResults.count, 2)
      XCTAssertEqual(
        try String(contentsOf: fixture.root.appending(path: "nested/new.txt"), encoding: .utf8),
        "three\n"
      )

      _ = try await fixture.service.managePath(
        ProjectManagePathRequest(
          projectID: fixture.projectID,
          action: .moveFile,
          relativePath: "nested/added.txt",
          destinationRelativePath: "moved.txt",
          destinationExpectedAbsent: true
        )
      )
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: fixture.root.appending(path: "nested/added.txt").path))
      XCTAssertEqual(
        try String(contentsOf: fixture.root.appending(path: "moved.txt"), encoding: .utf8),
        "added\n"
      )
    }

    func testTraversalPatchIsRejectedAndOutsideSentinelIsUnchanged() async throws {
      let fixture = try await makeFixture()
      let sentinel = fixture.root.deletingLastPathComponent()
        .appending(path: "bridge-windows-sentinel-\(UUID().uuidString).txt")
      try Data("outside\n".utf8).write(to: sentinel)
      defer {
        fixture.remove()
        try? FileManager.default.removeItem(at: sentinel)
      }

      let patchText = """
        *** Begin Patch
        *** Add File: ..\\\(sentinel.lastPathComponent)
        +overwritten
        *** End Patch
        """
      XCTAssertThrowsError(try ProjectPatchParser.parse(patchText))

      await assertMutationError(
        try await fixture.service.applyPatch(
          ProjectApplyPatchRequest(
            projectID: fixture.projectID,
            operations: [
              ProjectPatchFileOperation(
                action: "add",
                relativePath: "..\\\(sentinel.lastPathComponent)",
                hunks: [
                  ProjectPatchHunk(context: "", removals: [], additions: ["overwritten"])
                ]
              )
            ]
          )
        )
      ) { error in
        XCTAssertEqual(error, .forbiddenPath)
      }
      XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "outside\n")
    }

    func testForbiddenPatternsBlockWindowsWrites() async throws {
      let fixture = try await makeFixture(
        forbiddenPatterns: [try ForbiddenPathPattern("private/**")]
      )
      defer { fixture.remove() }

      await assertMutationError(
        try await fixture.service.write(
          ProjectWriteRequest(
            projectID: fixture.projectID,
            relativePath: "private/new.txt",
            mode: .create,
            content: "blocked",
            createParents: true
          )
        )
      ) { error in
        XCTAssertEqual(error, .forbiddenPath)
      }
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: fixture.root.appending(path: "private/new.txt").path)
      )
    }
  }

  private struct WindowsMutationFixture {
    let root: URL
    let projectID: ProjectID
    let service: RestrictedProjectMutationService

    func remove() {
      try? FileManager.default.removeItem(at: root)
    }
  }

  private func makeFixture(
    forbiddenPatterns: [ForbiddenPathPattern] = []
  ) async throws -> WindowsMutationFixture {
    let temporaryDirectory =
      ProcessInfo.processInfo.environment["TEMP"]
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.temporaryDirectory
    let root = temporaryDirectory.appending(
      path: "codex-bridge-windows-files-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let repository = InMemoryProjectRepository()
    let registry = ProjectRegistry(repository: repository)
    let summary = try await registry.register(
      local: try LocalProjectRegistration(
        name: "Windows Mutation Fixture",
        rootURL: root,
        accessPolicy: ProjectAccessPolicy(read: .allowed, write: .allowed, network: .denied),
        forbiddenPatterns: forbiddenPatterns
      )
    )
    return WindowsMutationFixture(
      root: root,
      projectID: summary.id,
      service: RestrictedProjectMutationService(repository: repository)
    )
  }

  private func assertMutationError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (ProjectMutationError) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      _ = try await expression()
      XCTFail("Expected mutation error", file: file, line: line)
    } catch let error as ProjectMutationError {
      handler(error)
    } catch {
      XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
  }
#endif

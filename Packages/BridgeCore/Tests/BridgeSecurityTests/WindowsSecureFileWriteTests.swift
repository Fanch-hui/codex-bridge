#if os(Windows)
  import Foundation
  import XCTest

  @testable import BridgeSecurity

  final class WindowsSecureFileWriteTests: XCTestCase {
    func testCreateAndReplaceAllowMissingLeafAndParents() throws {
      let rootURL = FileManager.default.temporaryDirectory
        .appending(path: "bridge-windows-write-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: rootURL) }

      let root = try RegisteredRoot(capturing: rootURL)
      let resolver = ProjectPathResolver(root: root)
      let writer = SecureProjectFileWriter()
      let path = try SecureRelativePath("nested/new.txt")
      let created = try writer.write(
        relativePath: path,
        through: resolver,
        mode: .create,
        content: Data("one\n".utf8),
        expectedSHA256: nil,
        createParents: true
      )
      let replaced = try writer.write(
        relativePath: path,
        through: resolver,
        mode: .replace,
        content: Data("two\n".utf8),
        expectedSHA256: created.newRevision.sha256,
        createParents: false
      )

      XCTAssertEqual(replaced.oldRevision, created.newRevision)
      XCTAssertEqual(
        try String(contentsOf: rootURL.appending(path: "nested/new.txt"), encoding: .utf8),
        "two\n"
      )
    }

    func testMoveAllowsMissingDestinationLeaf() throws {
      let rootURL = FileManager.default.temporaryDirectory
        .appending(path: "bridge-windows-move-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: rootURL) }

      let root = try RegisteredRoot(capturing: rootURL)
      let sourceURL = rootURL.appending(path: "source.txt")
      try Data("move me".utf8).write(to: sourceURL)
      let resolver = ProjectPathResolver(root: root)
      let mutation = SecureProjectDirectoryMutation()
      _ = try mutation.apply(
        action: .moveFile(sourceExpectedSHA256: nil, destinationExpectedAbsent: true),
        relativePath: try SecureRelativePath("source.txt"),
        destinationRelativePath: try SecureRelativePath("destination.txt"),
        through: resolver
      )

      XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: rootURL.appending(path: "destination.txt").path))
    }

    func testRelativePathRejectsWindowsTraversalAndDeviceNames() {
      for value in [
        "..\\outside.txt", "folder\\..\\outside.txt", "C:\\Windows\\win.ini", "CON.txt",
        "file.txt:stream",
      ] {
        XCTAssertThrowsError(try SecureRelativePath(value), value)
      }
    }
  }
#endif

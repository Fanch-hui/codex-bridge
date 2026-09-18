import Foundation
import XCTest

@testable import BridgeCodexService

final class ServiceWorkspaceChangeTrackerTests: XCTestCase {
  func testTracksCreatedModifiedAndRemovedFiles() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "bridge-workspace-change-tracker-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }

    let edited = root.appending(path: "edited.txt")
    let removed = root.appending(path: "removed.txt")
    try Data("before".utf8).write(to: edited)
    try Data("remove me".utf8).write(to: removed)
    let tracker = try XCTUnwrap(ServiceWorkspaceChangeTracker(projectRoot: root.path))

    try Data("after".utf8).write(to: edited)
    try FileManager.default.removeItem(at: removed)
    try Data("new".utf8).write(to: root.appending(path: "created.txt"))

    XCTAssertEqual(
      tracker.changedFiles(),
      ["created.txt", "edited.txt", "removed.txt"]
    )
  }

  func testIgnoresServiceAndGitMetadata() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "bridge-workspace-change-tracker-metadata-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: root.appending(path: ".git"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: root.appending(path: "node_modules/dependency"),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("before".utf8).write(to: root.appending(path: "tracked.txt"))
    try Data("before".utf8).write(to: root.appending(path: "service.sqlite"))
    try Data("before".utf8).write(to: root.appending(path: ".git/config"))
    let tracker = try XCTUnwrap(ServiceWorkspaceChangeTracker(projectRoot: root.path))

    try Data("after".utf8).write(to: root.appending(path: "service.sqlite"))
    try Data("after".utf8).write(to: root.appending(path: ".git/config"))
    try Data("generated".utf8).write(to: root.appending(path: "node_modules/dependency/index.js"))
    try Data("after".utf8).write(to: root.appending(path: "tracked.txt"))

    XCTAssertEqual(tracker.changedFiles(), ["tracked.txt"])
  }
}

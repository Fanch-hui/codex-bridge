import Foundation
import XCTest

@testable import BridgeServiceAppShell

final class MacAppUpdateHelperTests: XCTestCase {
  func testReplacementSwapsCompleteBundleAndPreservesAdjacentData() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? files.removeItem(at: root) }
    let current = root.appendingPathComponent("CodexBridge.app")
    let staged = root.appendingPathComponent("prepared.app")
    try files.createDirectory(at: current, withIntermediateDirectories: true)
    try files.createDirectory(at: staged, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: current.appendingPathComponent("old-binary"))
    try Data("new".utf8).write(to: staged.appendingPathComponent("new-binary"))
    let data = root.appendingPathComponent("user-data")
    try Data("history".utf8).write(to: data)

    try MacAppUpdateHelper.replace(staged: staged, target: current)

    XCTAssertEqual(
      try Data(contentsOf: current.appendingPathComponent("new-binary")), Data("new".utf8))
    XCTAssertFalse(files.fileExists(atPath: current.appendingPathComponent("old-binary").path))
    XCTAssertEqual(try Data(contentsOf: data), Data("history".utf8))
    XCTAssertEqual(
      try Data(contentsOf: staged.appendingPathComponent("old-binary")), Data("old".utf8))
  }
}

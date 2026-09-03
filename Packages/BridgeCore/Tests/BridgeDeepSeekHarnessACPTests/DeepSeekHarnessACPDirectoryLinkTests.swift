import BridgeAgentCore
import Foundation
import XCTest

@testable import BridgeDeepSeekHarnessACP

final class DeepSeekHarnessACPDirectoryLinkTests: XCTestCase {
  private var tempDirectory: URL!

  override func setUp() {
    super.setUp()
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("dsh-link-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
  }

  override func tearDown() {
    if let tempDirectory {
      try? FileManager.default.removeItem(at: tempDirectory)
    }
    super.tearDown()
  }

  func testCreateDirectoryLinkAndUnlinkSafely() throws {
    let targetDir = tempDirectory.appendingPathComponent("real_node_modules")
    try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

    let markerFile = targetDir.appendingPathComponent("marker.txt")
    try "hello from target".write(to: markerFile, atomically: true, encoding: .utf8)

    let linkPath = tempDirectory.appendingPathComponent("linked_node_modules").path
    try DeepSeekHarnessACPDirectoryLink.createDirectoryLink(
      atPath: linkPath,
      destinationPath: targetDir.path
    )

    let readThroughLink = URL(fileURLWithPath: linkPath).appendingPathComponent("marker.txt")
    let content = try String(contentsOf: readThroughLink, encoding: .utf8)
    XCTAssertEqual(content, "hello from target")

    // Remove the link
    DeepSeekHarnessACPDirectoryLink.removeDirectoryLink(atPath: linkPath)

    // Link should no longer exist
    XCTAssertFalse(FileManager.default.fileExists(atPath: linkPath))

    // Real target and its contents MUST STILL EXIST
    XCTAssertTrue(FileManager.default.fileExists(atPath: targetDir.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: markerFile.path))
    let targetContent = try String(contentsOf: markerFile, encoding: .utf8)
    XCTAssertEqual(targetContent, "hello from target")
  }

  func testRejectsRelativePath() {
    XCTAssertThrowsError(
      try DeepSeekHarnessACPDirectoryLink.createDirectoryLink(
        atPath: "relative/link",
        destinationPath: tempDirectory.path
      )
    )
  }

  func testRejectsNonExistentDestination() {
    let linkPath = tempDirectory.appendingPathComponent("bad_link").path
    let nonExistentTarget = tempDirectory.appendingPathComponent("does_not_exist").path
    XCTAssertThrowsError(
      try DeepSeekHarnessACPDirectoryLink.createDirectoryLink(
        atPath: linkPath,
        destinationPath: nonExistentTarget
      )
    )
  }

  func testRejectsOverwritingExistingDirectory() throws {
    let targetDir = tempDirectory.appendingPathComponent("target")
    try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

    let existingDir = tempDirectory.appendingPathComponent("existing")
    try FileManager.default.createDirectory(at: existingDir, withIntermediateDirectories: true)

    XCTAssertThrowsError(
      try DeepSeekHarnessACPDirectoryLink.createDirectoryLink(
        atPath: existingDir.path,
        destinationPath: targetDir.path
      )
    )
  }
}

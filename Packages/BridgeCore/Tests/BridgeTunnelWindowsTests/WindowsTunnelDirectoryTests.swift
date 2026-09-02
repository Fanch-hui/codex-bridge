import Foundation
import XCTest

@testable import BridgeTunnel

final class WindowsTunnelDirectoryTests: XCTestCase {
  private var rootURL: URL!

  override func setUpWithError() throws {
    let base = FileManager.default.temporaryDirectory.appending(
      path: "codexbridge-tunnel-dir-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    rootURL = base
  }

  override func tearDownWithError() throws {
    if let rootURL {
      try? FileManager.default.removeItem(at: rootURL)
    }
  }

  func testRunDirectoryLifecycle() throws {
    let root = try TunnelDirectoryHandle(existingRoot: rootURL)
    XCTAssertTrue(root.matchesPath())
    XCTAssertEqual(
      WindowsTunnelPathRules.normalize(root.path),
      WindowsTunnelPathRules.normalize(rootURL.path)
    )

    let run = try TunnelDirectoryHandle(creating: "r-abcdef123456", in: root)
    XCTAssertTrue(run.matchesPath())
    XCTAssertTrue(root.contains(name: "r-abcdef123456", directory: run))
    XCTAssertFalse(root.contains(name: "missing", directory: run))

    try run.createDirectory(name: "codex-home")
    XCTAssertTrue(run.matchesPath())

    let payload = Data("health.url\n".utf8)
    let healthURL = URL(fileURLWithPath: run.path).appendingPathComponent("health.url")
    try payload.write(to: healthURL)
    let read = try run.readRegularFile(name: "health.url", maximumBytes: 2_048)
    XCTAssertEqual(read, payload)

    try run.removeEntry(name: "health.url")
    XCTAssertThrowsError(try run.readRegularFile(name: "health.url", maximumBytes: 2_048))
    try run.removeEntry(name: "codex-home", directory: true)
    try root.removeEntry(name: "r-abcdef123456", directory: true)
    XCTAssertFalse(root.contains(name: "r-abcdef123456", directory: run))
  }

  func testIdentityPinningDetectsReplacement() throws {
    let root = try TunnelDirectoryHandle(existingRoot: rootURL)
    let run = try TunnelDirectoryHandle(creating: "r-abcdef123456", in: root)
    XCTAssertTrue(root.contains(name: "r-abcdef123456", directory: run))

    let runPath = URL(fileURLWithPath: run.path)
    try FileManager.default.removeItem(at: runPath)
    try FileManager.default.createDirectory(at: runPath, withIntermediateDirectories: true)

    XCTAssertFalse(run.matchesPath())
    XCTAssertFalse(root.contains(name: "r-abcdef123456", directory: run))
  }

  func testRejectsUnsafeEntryNames() throws {
    let root = try TunnelDirectoryHandle(existingRoot: rootURL)
    XCTAssertThrowsError(try TunnelDirectoryHandle(creating: "CON", in: root))
    XCTAssertThrowsError(try TunnelDirectoryHandle(creating: "a/b", in: root))
    XCTAssertThrowsError(try root.createDirectory(name: ".."))
    XCTAssertThrowsError(try root.removeEntry(name: "a\\b"))
    XCTAssertEqual(
      try? FileManager.default.contentsOfDirectory(atPath: rootURL.path).count,
      0
    )
  }

  func testBoundedReadRejectsOversizedFile() throws {
    let root = try TunnelDirectoryHandle(existingRoot: rootURL)
    let run = try TunnelDirectoryHandle(creating: "r-abcdef123456", in: root)
    let payload = Data(repeating: 0x61, count: 4_096)
    let fileURL = URL(fileURLWithPath: run.path).appendingPathComponent("observed.json")
    try payload.write(to: fileURL)
    XCTAssertThrowsError(
      try run.readRegularFile(name: "observed.json", maximumBytes: 1_024)
    )
    XCTAssertEqual(
      try run.readRegularFile(name: "observed.json", maximumBytes: 4_096),
      payload
    )
  }
}

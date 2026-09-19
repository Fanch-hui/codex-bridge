import BridgeAgentCore
import Foundation
import XCTest

@testable import BridgeDeepSeekHarnessACP

final class DeepSeekHarnessACPSourceRootTests: XCTestCase {
  func testFindsSourceRootWhileTraversingToFilesystemRoot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = root.appendingPathComponent("deepseek-harness")
    let entry = source.appendingPathComponent("apps/cli/lib/bin.js")
    try FileManager.default.createDirectory(
      at: entry.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("{}".utf8).write(to: source.appendingPathComponent("package.json"))
    try Data("lockfileVersion: '9.0'".utf8).write(
      to: source.appendingPathComponent("pnpm-lock.yaml"))
    let executable = try XCTUnwrap(AgentPathSemantics.canonicalPath(entry.path))
    let actual = try DeepSeekHarnessACPArtifactRuntime.findSourceRoot(startingAt: executable)
    XCTAssertEqual(actual, AgentPathSemantics.canonicalPath(source.path))
  }
}

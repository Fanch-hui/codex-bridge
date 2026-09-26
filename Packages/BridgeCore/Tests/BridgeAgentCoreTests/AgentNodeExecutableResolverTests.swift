import Foundation
import XCTest

@testable import BridgeAgentCore

final class AgentNodeExecutableResolverTests: XCTestCase {
  func testFindsNodeBesideVersionManagedPackageWithEmptyPATH() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    #if os(Windows)
      let node = root.appendingPathComponent("node.exe")
      let entry = root.appendingPathComponent(
        "node_modules/@qodercn-ai/qoderclicn/bundle/qoderclicn.js")
    #else
      let node = root.appendingPathComponent("bin/node")
      let entry = root.appendingPathComponent(
        "lib/node_modules/@qodercn-ai/qoderclicn/bundle/qoderclicn.js")
    #endif
    try FileManager.default.createDirectory(
      at: node.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("node-runtime".utf8).write(to: node)
    try Data("cli-entry".utf8).write(to: entry)
    #if !os(Windows)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: node.path)
    #endif
    let resolved = AgentNodeExecutableResolver.resolve(near: entry.path, environment: ["PATH": ""])
    XCTAssertEqual(resolved, AgentPathSemantics.canonicalPath(node.resolvingSymlinksInPath().path))
  }
}

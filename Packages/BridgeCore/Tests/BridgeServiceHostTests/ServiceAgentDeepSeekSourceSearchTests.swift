import Foundation
import XCTest

@testable import BridgeServiceHost

final class ServiceAgentDeepSeekSourceSearchTests: XCTestCase {
  func testFindsBuiltCheckoutUnderCustomDevelopmentDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "bridge-dsh-source-search-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let sourceRoot = root.appendingPathComponent("Dev/团队甲/deepseek-harness", isDirectory: true)
    try makeSourceTree(at: sourceRoot, name: "deepseek-harness")
    defer { try? FileManager.default.removeItem(at: root) }

    let found = ServiceAgentDeepSeekSourceSearch.discover(
      environment: ["HOME": root.path],
      limits: .init(maximumDirectories: 64, maximumDepth: 5, maximumMilliseconds: 2_000),
      anchors: [root.appendingPathComponent("Dev", isDirectory: true).path]
    )

    XCTAssertEqual(found, [sourceRoot.standardizedFileURL.path])
  }

  func testAcceptsSourceRootAnchor() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "bridge-dsh-source-anchor-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try makeSourceTree(at: root, name: "@deepseek-ai/dsh-root")
    defer { try? FileManager.default.removeItem(at: root) }

    let found = ServiceAgentDeepSeekSourceSearch.discover(
      environment: ["HOME": "/empty"],
      limits: .init(maximumDirectories: 16, maximumDepth: 2, maximumMilliseconds: 2_000),
      anchors: [root.path]
    )

    XCTAssertEqual(found, [root.standardizedFileURL.path])
  }

  func testRejectsNonDSHManifest() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "bridge-dsh-source-search-invalid-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try makeSourceTree(
      at: root.appendingPathComponent("Projects/unrelated", isDirectory: true),
      name: "unrelated-cli"
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let found = ServiceAgentDeepSeekSourceSearch.discover(
      environment: ["HOME": root.path],
      limits: .init(maximumDirectories: 64, maximumDepth: 5, maximumMilliseconds: 2_000),
      anchors: [root.path]
    )

    XCTAssertTrue(found.isEmpty)
  }

  #if !os(Windows)
    func testDoesNotFollowSourceSymlink() throws {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-dsh-source-search-link-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      let sourceRoot = FileManager.default.temporaryDirectory.appending(
        path: "bridge-dsh-source-search-link-target-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      let linkParent = root.appendingPathComponent("Dev", isDirectory: true)
      let link = linkParent.appendingPathComponent("deepseek-harness", isDirectory: true)
      try makeSourceTree(at: sourceRoot, name: "deepseek-harness")
      try FileManager.default.createDirectory(at: linkParent, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sourceRoot)
      defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: sourceRoot)
      }

      let found = ServiceAgentDeepSeekSourceSearch.discover(
        environment: ["HOME": root.path],
        limits: .init(maximumDirectories: 64, maximumDepth: 5, maximumMilliseconds: 2_000),
        anchors: [root.path]
      )

      XCTAssertTrue(found.isEmpty)
    }
  #endif

  private func makeSourceTree(at root: URL, name: String) throws {
    let entry = root.appendingPathComponent("apps/cli/lib/bin.js")
    try FileManager.default.createDirectory(
      at: entry.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("#!/usr/bin/env node\n".utf8).write(to: entry)
    try Data("{\"name\":\"\(name)\"}".utf8).write(
      to: root.appendingPathComponent("package.json")
    )
    try Data("lockfileVersion: '9.0'\n".utf8).write(
      to: root.appendingPathComponent("pnpm-lock.yaml")
    )
  }
}

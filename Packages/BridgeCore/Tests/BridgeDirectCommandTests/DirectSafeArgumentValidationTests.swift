import Foundation
import XCTest

@testable import BridgeDirectCommand

final class DirectSafeArgumentValidationTests: XCTestCase {
  func testGitReadOnlyArgumentsAndDangerousLongOptionPrefixes() throws {
    let root = try makeRoot("direct-safe-arguments-git")
    defer { try? FileManager.default.removeItem(at: root) }

    for argv in [
      ["git", "branch", "--show-current"],
      ["git", "branch", "--list", "feature/*"],
      ["git", "tag", "--list", "v1.*"],
      ["git", "describe", "--tags", "--always"],
      ["git", "log", "--pretty=medium"],
    ] {
      XCTAssertTrue(isSafe(argv, root: root), argv.joined(separator: " "))
    }

    for argv in [
      ["git", "branch", "-D", "feature"],
      ["git", "branch", "-m", "old", "new"],
      ["git", "tag", "--delete", "v1.0.0"],
      ["git", "status", "--ext-d"],
      ["git", "status", "--out=/tmp/result"],
      ["git", "log", "--pretty=%(signature)"],
      ["git", "diff", "--remerge-diff"],
    ] {
      XCTAssertFalse(isSafe(argv, root: root), argv.joined(separator: " "))
    }
  }

  func testSearchAndLsRejectSymlinkFollowingOptionsAndEscapes() throws {
    let root = try makeRoot("direct-safe-arguments-search")
    let outside = try makeRoot("direct-safe-arguments-search-outside")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }

    for argv in [
      ["grep", "-in", "needle", "."],
      ["rg", "-n", "needle", "."],
      ["ls", "-la", "."],
    ] {
      XCTAssertTrue(isSafe(argv, root: root), argv.joined(separator: " "))
    }
    for argv in [
      ["grep", "-Rin", "needle", "."],
      ["grep", "--dereference-recursive", "needle", "."],
      ["rg", "-nL", "needle", "."],
      ["rg", "--follow", "needle", "."],
      ["ls", "-RL", "."],
      ["ls", "-H", "."],
      ["ls", "--dereference-recursive", "."],
    ] {
      XCTAssertFalse(isSafe(argv, root: root), argv.joined(separator: " "))
    }

    let link = root.appendingPathComponent("linked")
    do {
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    } catch {
      throw XCTSkip("symbolic links are unavailable in this test environment")
    }
    for executable in ["grep", "rg"] {
      XCTAssertFalse(isSafe([executable, "needle", link.path], root: root))
    }
    XCTAssertFalse(isSafe(["ls", "-la", link.path], root: root))
  }

  func testNodeCheckAndVersionArgumentsRemainExact() throws {
    let root = try makeRoot("direct-safe-arguments-node")
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("check.js")
    try Data("const value = 1;\n".utf8).write(to: script)
    XCTAssertTrue(isSafe(["node", "--check", script.path], root: root))

    for argv in [
      ["node", "--require", "module", "--check", script.path],
      ["node", "--check", "--import", "module", script.path],
      ["node", script.path],
      ["node", "--test", script.path],
    ] {
      XCTAssertFalse(isSafe(argv, root: root), argv.joined(separator: " "))
    }

    var versions = [
      ["node", "--version"],
      ["npm", "--version"],
      ["swift", "--version"],
      ["rg", "--version"],
    ]
    #if !os(Windows)
      versions.append(["xcodebuild", "-version"])
    #endif
    for argv in versions {
      XCTAssertTrue(isSafe(argv, root: root), argv.joined(separator: " "))
      XCTAssertFalse(isSafe(argv + ["extra"], root: root), argv.joined(separator: " "))
    }
  }

  private func makeRoot(_ prefix: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
  }

  private func isSafe(_ argv: [String], root: URL) -> Bool {
    DirectCommandPolicy().safeBuiltInInvocation(
      argv,
      projectRoot: root.path,
      workingDirectory: nil
    )
  }
}

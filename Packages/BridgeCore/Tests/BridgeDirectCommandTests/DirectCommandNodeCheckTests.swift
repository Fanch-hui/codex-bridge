import Foundation
import XCTest

@testable import BridgeDirectCommand

final class DirectCommandNodeCheckTests: XCTestCase {
  func testNodeCheckAllowsProjectLocalJavaScriptFiles() throws {
    let root = try makeRoot("direct-policy-node-check-root")
    defer { try? FileManager.default.removeItem(at: root) }
    for extensionName in ["js", "mjs", "cjs"] {
      let file = root.appendingPathComponent("script.\(extensionName)")
      try Data("const value = 1;\n".utf8).write(to: file)
      let argv = ["node", "--check", file.path]
      XCTAssertTrue(isSafe(argv, root: root), argv.joined(separator: " "))
    }
  }

  func testNodeCheckRejectsCodeLoadingAndExecutionOptions() throws {
    let root = try makeRoot("direct-policy-node-check-options")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("script.js")
    try Data("const value = 1;\n".utf8).write(to: file)
    let injections = [
      ["--require", "module"],
      ["-r", "module"],
      ["--import", "module"],
      ["-e", "console.log(1)"],
      ["--eval", "console.log(1)"],
    ]
    for injection in injections {
      let argv = ["node", "--check"] + injection + [file.path]
      XCTAssertFalse(isSafe(argv, root: root), argv.joined(separator: " "))
    }

    for argv in [
      ["node", "--require", "module", "--check", file.path],
      ["node", "--import", "module", "--check", file.path],
    ] {
      XCTAssertFalse(isSafe(argv, root: root), argv.joined(separator: " "))
    }
  }

  func testNodeNormalExecutionAndNodeTestAreNotBuiltInSafe() throws {
    let root = try makeRoot("direct-policy-node-check-execution")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("script.js")
    try Data("const value = 1;\n".utf8).write(to: file)
    for argv in [
      ["node", file.path],
      ["node", "--test", file.path],
    ] {
      XCTAssertFalse(isSafe(argv, root: root), argv.joined(separator: " "))
    }
  }

  func testNodeCheckRejectsOutsideFilesAndSymlinks() throws {
    let root = try makeRoot("direct-policy-node-check-project")
    let outside = try makeRoot("direct-policy-node-check-outside")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let outsideFile = outside.appendingPathComponent("outside.js")
    try Data("const outside = true;\n".utf8).write(to: outsideFile)
    let escapedPath = root.appendingPathComponent(
      "../" + outside.lastPathComponent + "/outside.js"
    ).path
    for path in [outsideFile.path, escapedPath] {
      let argv = ["node", "--check", path]
      XCTAssertFalse(isSafe(argv, root: root), argv.joined(separator: " "))
    }

    let link = root.appendingPathComponent("linked.js")
    do {
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideFile)
    } catch {
      throw XCTSkip("symbolic links are unavailable in this test environment")
    }
    let argv = ["node", "--check", link.path]
    XCTAssertFalse(isSafe(argv, root: root), argv.joined(separator: " "))
  }

  func testNodeCheckRejectsNonJavaScriptFiles() throws {
    let root = try makeRoot("direct-policy-node-check-extension")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("script.txt")
    try Data("const value = 1;\n".utf8).write(to: file)
    let argv = ["node", "--check", file.path]
    XCTAssertFalse(isSafe(argv, root: root))
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

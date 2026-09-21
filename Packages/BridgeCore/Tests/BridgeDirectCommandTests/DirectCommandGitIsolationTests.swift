import BridgeDirectCommand
import Foundation
import XCTest

final class DirectCommandGitIsolationTests: XCTestCase {
  func testSafeGitCommandsDisableConfiguredFsmonitorAndTextconvScripts() throws {
    #if os(Windows)
      throw XCTSkip("shell hook isolation uses the macOS Git executable in this test")
    #else
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("direct-policy-git-isolation-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }

      let fsmonitorMarker = root.appendingPathComponent("fsmonitor-ran")
      let fsmonitorScript = try writeExecutableScript(
        at: root.appendingPathComponent("fsmonitor.sh"),
        body: "touch \(fsmonitorMarker.path)\n"
      )
      let textconvMarker = root.appendingPathComponent("textconv-ran")
      let textconvScript = try writeExecutableScript(
        at: root.appendingPathComponent("textconv.sh"),
        body: "touch \(textconvMarker.path)\ncat \"$1\"\n"
      )

      try runGit(["init"], at: root)
      try runGit(["config", "user.name", "Safe Test"], at: root)
      try runGit(["config", "user.email", "safe-test@example.invalid"], at: root)
      try runGit(["config", "core.fsmonitor", fsmonitorScript.path], at: root)
      try runGit(["config", "diff.safe.textconv", textconvScript.path], at: root)
      try Data("data.txt diff=safe\n".utf8)
        .write(to: root.appendingPathComponent(".gitattributes"))
      try Data("before\n".utf8).write(to: root.appendingPathComponent("data.txt"))
      try runGit(["add", ".gitattributes", "data.txt"], at: root)
      try runGit(["commit", "-m", "baseline"], at: root)
      try Data("after\n".utf8).write(to: root.appendingPathComponent("data.txt"))
      try? FileManager.default.removeItem(at: fsmonitorMarker)
      try? FileManager.default.removeItem(at: textconvMarker)

      let project = try DirectCommandPolicyTestSupport.project(root: root)
      let policy = DirectCommandPolicy()
      let status = policy.resolve(
        project: project,
        request: DirectCommandRequest(
          projectID: project.id,
          commandID: nil,
          argv: ["/usr/bin/git", "status"]
        )
      )
      XCTAssertTrue(status.allowed)
      XCTAssertTrue(status.argv.contains("core.fsmonitor=false"))
      try runGit(Array(status.argv.dropFirst()), at: root)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fsmonitorMarker.path))

      let diff = policy.resolve(
        project: project,
        request: DirectCommandRequest(
          projectID: project.id,
          commandID: nil,
          argv: ["/usr/bin/git", "diff"]
        )
      )
      XCTAssertTrue(diff.allowed)
      XCTAssertTrue(diff.argv.contains("--no-ext-diff"))
      XCTAssertTrue(diff.argv.contains("--no-textconv"))
      try runGit(Array(diff.argv.dropFirst()), at: root)
      XCTAssertFalse(FileManager.default.fileExists(atPath: textconvMarker.path))
    #endif
  }

  private func writeExecutableScript(at url: URL, body: String) throws -> URL {
    try Data("#!/bin/sh\n\(body)".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  @discardableResult
  private func runGit(_ arguments: [String], at root: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "DirectCommandGitIsolationTests",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)]
      )
    }
    return String(decoding: data, as: UTF8.self)
  }
}

import BridgeDirectCommand
import BridgeServiceCore
import Foundation
import XCTest

final class DirectCommandSafeBuiltInTests: XCTestCase {
  func testGitBranchAllowsReadOnlyFormsAndRejectsMutations() throws {
    let policy = DirectCommandPolicy()
    let project = try DirectCommandPolicyTestSupport.project()

    for argv in [
      ["git", "branch", "--show-current"],
      ["git", "branch", "--list"],
      ["git", "branch", "--list", "feature/*"],
    ] {
      let result = try DirectCommandPolicyTestSupport.resolveBuiltIn(
        argv, policy: policy, project: project)
      XCTAssertTrue(result.allowed, argv.joined(separator: " "))
      XCTAssertNil(result.reason, argv.joined(separator: " "))
    }

    for argv in [
      ["git", "branch", "-d", "feature"],
      ["git", "branch", "-D", "feature"],
      ["git", "branch", "-m", "old", "new"],
      ["git", "branch", "-M", "old", "new"],
      ["git", "branch", "-f", "feature"],
      ["git", "branch", "--delete", "feature"],
      ["git", "branch", "--move", "old", "new"],
    ] {
      let result = try DirectCommandPolicyTestSupport.resolveBuiltIn(
        argv, policy: policy, project: project)
      XCTAssertFalse(result.allowed, argv.joined(separator: " "))
    }
  }

  func testGitTagListAndDescribeAreReadOnlyBuiltIns() throws {
    let project = try DirectCommandPolicyTestSupport.project()

    for argv in [
      ["git", "tag", "--list"],
      ["git", "tag", "--list", "v1.*"],
      ["git", "describe", "--tags", "--always"],
    ] {
      let result = try DirectCommandPolicyTestSupport.resolveBuiltIn(argv, project: project)
      XCTAssertTrue(result.allowed, argv.joined(separator: " "))
      XCTAssertNil(result.reason, argv.joined(separator: " "))
    }

    for argv in [
      ["git", "tag", "--annotate", "v1.0.0"],
      ["git", "tag", "--delete", "v1.0.0"],
      ["git", "tag", "-f", "v1.0.0"],
    ] {
      let result = try DirectCommandPolicyTestSupport.resolveBuiltIn(argv, project: project)
      XCTAssertFalse(result.allowed, argv.joined(separator: " "))
    }
  }

  func testSearchRejectsSymlinkTraversalFlagsAndShortClusters() throws {
    let project = try DirectCommandPolicyTestSupport.project()
    let rejected = [
      ["grep", "-R", "needle", "."],
      ["grep", "--dereference-recursive", "needle", "."],
      ["grep", "-Rin", "needle", "."],
      ["rg", "-L", "needle", "."],
      ["rg", "--follow", "needle", "."],
      ["rg", "-nL", "needle", "."],
      ["rg", "-iL", "needle", "."],
    ]

    for argv in rejected {
      let result = try DirectCommandPolicyTestSupport.resolveBuiltIn(argv, project: project)
      XCTAssertFalse(result.allowed, argv.joined(separator: " "))
      XCTAssertEqual(result.reason, .invalidArguments, argv.joined(separator: " "))
    }
  }

  func testSearchRejectsProjectSymlinkThatEscapesRoot() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("direct-policy-search-root-\(UUID().uuidString)")
    let outside = FileManager.default.temporaryDirectory
      .appendingPathComponent("direct-policy-search-outside-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }

    let outsideFile = outside.appendingPathComponent("secret.txt")
    try Data("outside\n".utf8).write(to: outsideFile)
    let link = root.appendingPathComponent("linked")
    do {
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    } catch {
      throw XCTSkip("symbolic links are unavailable in this test environment")
    }

    let project = try DirectCommandPolicyTestSupport.project(root: root)
    for executable in ["grep", "rg"] {
      let argv = [executable, "outside", link.path]
      let result = try DirectCommandPolicyTestSupport.resolveBuiltIn(argv, project: project)
      XCTAssertFalse(result.allowed, argv.joined(separator: " "))
      XCTAssertEqual(result.reason, .invalidArguments, argv.joined(separator: " "))
    }
  }

  func testBuildAndTestCommandsAreNotBuiltInSafe() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("direct-policy-build-root-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = try DirectCommandPolicyTestSupport.project(root: root)
    let xcodeProject = root.appendingPathComponent("Project.xcodeproj").path

    let commands = [
      ["swift", "build"],
      ["swift", "test"],
      ["npm", "test"],
      ["npm", "run", "build"],
      ["npm", "run", "lint"],
      ["npm", "run", "typecheck"],
      ["npm", "run", "test"],
      ["xcodebuild", "-project", xcodeProject],
      ["xcodebuild", "-workspace", root.appendingPathComponent("Project.xcworkspace").path],
    ]
    for argv in commands {
      let result = DirectCommandPolicyTestSupport.resolve(argv, project: project)
      XCTAssertFalse(result.allowed, argv.joined(separator: " "))
      XCTAssertEqual(result.reason, .commandNotRegistered, argv.joined(separator: " "))
    }
  }

  func testExplicitlyRegisteredBuildCommandStillUsesApprovalPath() throws {
    let command = try ServiceWorkspaceCommand(
      id: "registered-npm-test",
      name: "Project tests",
      executable: "npm",
      arguments: ["test"]
    )
    let project = try DirectCommandPolicyTestSupport.project(
      write: .requiresLocalApproval,
      commands: [command]
    )
    let result = DirectCommandPolicy().resolve(
      project: project,
      request: DirectCommandRequest(
        projectID: project.id,
        commandID: command.id,
        argv: []
      )
    )
    XCTAssertTrue(result.allowed)
    XCTAssertTrue(result.requiresApproval)
    XCTAssertEqual(result.argv, ["npm", "test"])
  }
}

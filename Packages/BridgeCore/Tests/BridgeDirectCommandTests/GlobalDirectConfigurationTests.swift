import BridgeDirectCommand
import BridgeDomain
import BridgeProjects
import BridgeSecurity
import BridgeServiceCore
import Foundation
import XCTest

final class GlobalDirectConfigurationTests: XCTestCase {
  func testCommandLineParsesQuotesAndWindowsPaths() throws {
    XCTAssertEqual(
      try DirectCommandLine.parse("git commit -m 'two words'"),
      ["git", "commit", "-m", "two words"])
    XCTAssertEqual(
      try DirectCommandLine.parse(#""D:\Tools\my tool.exe" test"#),
      [#"D:\Tools\my tool.exe"#, "test"])
    XCTAssertEqual(
      try DirectCommandLine.parse(#"\\server\tools\runner.exe test"#),
      [#"\\server\tools\runner.exe"#, "test"])
    XCTAssertThrowsError(try DirectCommandLine.parse("git status && git push"))
  }

  func testGlobalRulesOverrideBuiltInsAndBlacklistWinsAcrossProjects() throws {
    let configuration = ServiceDirectConfiguration(
      allowedCommands: ["find . -delete", "git"], deniedCommands: ["git push"])
    let policy = DirectCommandPolicy()
    for id in ["first", "second"] {
      let project = try configuration.applying(
        to: ServiceProjectRecord(
          id: ProjectID(rawValue: id), name: id,
          root: ServiceRootIdentity(capturing: FileManager.default.temporaryDirectory),
          accessPolicy: ProjectAccessPolicy(read: .allowed, write: .allowed, network: .allowed),
          createdAt: Date(), updatedAt: Date()
        ))
      func resolve(_ argv: [String]) -> DirectCommandResolution {
        policy.resolve(
          project: project,
          request: DirectCommandRequest(projectID: project.id, commandID: nil, argv: argv))
      }
      let remaining = try ServiceDirectConfiguration(allowedCommands: ["git"]).applying(to: project)
      XCTAssertEqual(remaining.workspaceCommands.first?.id, project.workspaceCommands.last?.id)
      XCTAssertTrue(resolve(["find", ".", "-delete"]).allowed)
      XCTAssertTrue(resolve(["git", "status"]).allowed)
      XCTAssertEqual(resolve(["git", "push", "origin"]).reason, .blacklisted)
      XCTAssertTrue(resolve(["git", "log", "--grep=push"]).allowed)
    }
  }
}

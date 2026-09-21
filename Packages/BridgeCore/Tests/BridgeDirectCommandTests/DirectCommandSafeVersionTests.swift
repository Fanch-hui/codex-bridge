import BridgeDirectCommand
import XCTest

final class DirectCommandSafeVersionTests: XCTestCase {
  func testVersionCommandsAreSafeOnlyWithTheirExactArguments() throws {
    let project = try DirectCommandPolicyTestSupport.project()
    var allowed = [
      ["node", "--version"],
      ["npm", "--version"],
      ["swift", "--version"],
      ["rg", "--version"],
    ]
    #if !os(Windows)
      allowed.append(["xcodebuild", "-version"])
    #endif

    for argv in allowed {
      let result = try DirectCommandPolicyTestSupport.resolveBuiltIn(argv, project: project)
      XCTAssertTrue(result.allowed, argv.joined(separator: " "))
      XCTAssertNil(result.reason, argv.joined(separator: " "))
    }

    for argv in allowed.map({ $0 + ["extra"] }) {
      let result = try DirectCommandPolicyTestSupport.resolveBuiltIn(argv, project: project)
      XCTAssertFalse(result.allowed, argv.joined(separator: " "))
    }
  }
}

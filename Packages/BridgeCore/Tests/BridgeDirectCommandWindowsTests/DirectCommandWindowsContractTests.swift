#if os(Windows)
  import XCTest

  @testable import BridgeDirectCommand

  final class DirectCommandWindowsContractTests: XCTestCase {
    func testBuiltInSafeCommandsExcludeDangerousCommands() {
      let policy = DirectCommandPolicy()
      let rules = policy.effectiveSafeCommandRules
      XCTAssertFalse(rules.contains { $0.executable.lowercased() == "echo" })
      XCTAssertFalse(rules.contains { $0.executable.lowercased() == "pwd" })
      XCTAssertFalse(rules.contains { $0.executable.lowercased() == "find" })
      XCTAssertFalse(
        rules.contains {
          $0.executable.lowercased() == "npm" && $0.argumentsPrefix.contains("test")
        })
    }

    func testDenyNetworkFailsClosedOnInvalidExecutable() {
      let output = DirectCommandOutputCollector(maximumBytes: 1_024)
      XCTAssertThrowsError(
        try DirectProcessLifetime(
          argv: [""],
          workingDirectory: nil,
          environment: nil,
          usePTY: false,
          output: output,
          denyNetwork: true
        )
      ) { error in
        XCTAssertEqual(error as? DirectProcessError, .invalidArgument)
      }
    }
  }
#endif

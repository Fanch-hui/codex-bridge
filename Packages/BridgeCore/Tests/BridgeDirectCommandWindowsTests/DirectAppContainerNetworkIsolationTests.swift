#if os(Windows)
  import Foundation
  import WinSDK
  import XCTest

  @testable import BridgeDirectCommand

  final class DirectAppContainerNetworkIsolationTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
      super.setUp()
      tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ac-test-\(Foundation.UUID().uuidString)")
      try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
      if let tempDirectory {
        try? FileManager.default.removeItem(at: tempDirectory)
      }
      super.tearDown()
    }

    func testAppContainerBlocksNetworkSockets() throws {
      let output = DirectCommandOutputCollector(maximumBytes: 4096)
      let lifetime = try DirectProcessLifetime(
        argv: [#"C:\Windows\System32\ping.exe"#, "-n", "1", "127.0.0.1"],
        workingDirectory: tempDirectory.path,
        environment: nil,
        usePTY: false,
        output: output,
        denyNetwork: true
      )
      let termination = lifetime.waitForExit(timeout: .seconds(10))
      guard case .exited(let code) = termination else {
        XCTFail("Process did not exit cleanly: \(String(describing: termination))")
        return
      }
      XCTAssertNotEqual(code, 0, "Loopback connection must be denied inside AppContainer")
    }

    func testAppContainerWorkspaceAccessSucceeds() throws {
      let output = DirectCommandOutputCollector(maximumBytes: 4096)
      let lifetime = try DirectProcessLifetime(
        argv: [#"C:\Windows\System32\cmd.exe"#, "/c", "echo WORKSPACE_OK > out.txt"],
        workingDirectory: tempDirectory.path,
        environment: nil,
        usePTY: false,
        output: output,
        denyNetwork: true
      )
      let termination = lifetime.waitForExit(timeout: .seconds(10))
      XCTAssertEqual(termination, .exited(0))

      let outFile = tempDirectory.appendingPathComponent("out.txt")
      XCTAssertTrue(FileManager.default.fileExists(atPath: outFile.path))
      let content = try String(contentsOf: outFile, encoding: .utf8)
      XCTAssertTrue(content.contains("WORKSPACE_OK"))
    }

    func testAppContainerUsesOnlySuppliedEnvironment() throws {
      let parentKey =
        "BRIDGE_TEST_PARENT_" + Foundation.UUID().uuidString.replacingOccurrences(of: "-", with: "")
      let inherited = parentKey.withCString(encodedAs: UTF16.self) { key in
        "parent-only".withCString(encodedAs: UTF16.self) { SetEnvironmentVariableW(key, $0) }
      }
      XCTAssertTrue(inherited)
      defer {
        _ = parentKey.withCString(encodedAs: UTF16.self) { SetEnvironmentVariableW($0, nil) }
      }
      let output = DirectCommandOutputCollector(maximumBytes: 4096)
      let lifetime = try DirectProcessLifetime(
        argv: [
          #"C:\Windows\System32\cmd.exe"#, "/d", "/c",
          "if defined \(parentKey) (exit /b 11) else (echo %BRIDGE_TEST_CHILD%>environment.txt)",
        ],
        workingDirectory: tempDirectory.path,
        environment: ["SystemRoot": #"C:\Windows"#, "BRIDGE_TEST_CHILD": "kept"],
        usePTY: false,
        output: output,
        denyNetwork: true
      )
      XCTAssertEqual(lifetime.waitForExit(timeout: .seconds(10)), .exited(0))
      let content = try String(
        contentsOf: tempDirectory.appendingPathComponent("environment.txt"), encoding: .utf8)
      XCTAssertEqual(content.trimmingCharacters(in: .whitespacesAndNewlines), "kept")
    }

    func testAppContainerJobObjectTreeTermination() throws {
      let output = DirectCommandOutputCollector(maximumBytes: 4096)
      let lifetime = try DirectProcessLifetime(
        argv: [#"C:\Windows\System32\timeout.exe"#, "60"],
        workingDirectory: tempDirectory.path,
        environment: nil,
        usePTY: false,
        output: output,
        denyNetwork: true
      )
      XCTAssertTrue(lifetime.isRunning)
      lifetime.terminateGroup()
      let termination = lifetime.waitForExit(timeout: .seconds(5))
      XCTAssertNotNil(termination)
      XCTAssertFalse(lifetime.isRunning)
    }

    func testWindowsSafeCommandsRulesAudit() {
      let policy = DirectCommandPolicy()
      let rules = policy.effectiveSafeCommandRules

      XCTAssertFalse(rules.contains { $0.executable.lowercased() == "echo" })
      XCTAssertFalse(rules.contains { $0.executable.lowercased() == "pwd" })
      XCTAssertFalse(rules.contains { $0.executable.lowercased() == "ls" })
      XCTAssertFalse(rules.contains { $0.executable.lowercased() == "grep" })
      XCTAssertFalse(rules.contains { $0.executable.lowercased() == "find" })
      XCTAssertFalse(rules.contains { $0.executable.lowercased() == "xcodebuild" })

      XCTAssertFalse(
        rules.contains {
          $0.executable.lowercased() == "npm" && $0.argumentsPrefix.contains("test")
        })
      XCTAssertFalse(
        rules.contains {
          $0.executable.lowercased() == "swift" && $0.argumentsPrefix.contains("test")
        })
      XCTAssertFalse(
        rules.contains {
          $0.executable.lowercased() == "npm" && $0.argumentsPrefix.contains("build")
        })
      XCTAssertFalse(
        rules.contains {
          $0.executable.lowercased() == "swift" && $0.argumentsPrefix.contains("build")
        })

      for rule in rules where rule.executable.lowercased() == "git" {
        let safeSubcommands = [
          "status", "diff", "log", "show", "branch", "tag", "describe", "rev-parse", "ls-files",
          "--version",
        ]
        XCTAssertTrue(rule.argumentsPrefix.first.map { safeSubcommands.contains($0) } ?? false)
        if rule.argumentsPrefix.first == "tag" {
          XCTAssertEqual(rule.argumentsPrefix, ["tag", "--list"])
        }
        if rule.argumentsPrefix.first == "branch" {
          XCTAssertTrue(
            [["branch", "--list"], ["branch", "--show-current"]].contains(rule.argumentsPrefix))
        }
      }
    }
  }
#endif

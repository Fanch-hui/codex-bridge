#if os(Windows)
  import Foundation
  import XCTest

  @testable import BridgeSkills

  final class SkillActionInterpreterWindowsTests: XCTestCase {
    func testParsedShellActionRunsThroughWindowsShell() async throws {
      guard SkillActionInterpreter.resolveInterpreter("sh") != nil else {
        throw XCTSkip("Git for Windows shell is unavailable")
      }
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bridge-skill-windows-\(UUID().uuidString)", isDirectory: true)
      let skill = root.appendingPathComponent("skills/windows-shell", isDirectory: true)
      let scripts = skill.appendingPathComponent("scripts", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: root) }

      try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
      let manifestText = """
        ---
        name: windows-shell
        actions:
          - name: printf
            script: scripts/printf.sh
            interpreter: /bin/sh
            network_requirement: denied
        ---
        """
      try Data(manifestText.utf8).write(to: skill.appendingPathComponent("SKILL.md"))
      try Data("#!/bin/sh\nprintf 'windows-shell-ok\\n'\n".utf8)
        .write(to: scripts.appendingPathComponent("printf.sh"))

      let scanner = SkillScanner(globalRoots: [root.appendingPathComponent("skills")])
      let manifests = try await scanner.scanSkills(for: nil)
      let manifest = try XCTUnwrap(manifests.first)
      let launch = try await scanner.resolveAction("printf", in: manifest)

      let process = Process()
      process.executableURL = URL(fileURLWithPath: launch.interpreter)
      process.arguments = Array(launch.argvPrefix.dropFirst())
      let output = Pipe()
      process.standardOutput = output
      process.standardError = output
      try process.run()
      process.waitUntilExit()

      XCTAssertEqual(process.terminationStatus, 0)
      XCTAssertEqual(
        String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
        "windows-shell-ok\n"
      )
    }
  }
#endif

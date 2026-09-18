#if os(Windows)
  import BridgeProcess
  import Foundation
  import XCTest

  final class ManagedStdioProcessWindowsTests: XCTestCase {
    func testManagedProcessRoundTripsStdinStdoutAndExitCode() throws {
      let output = BoundedProcessOutputCollector(maximumBytes: 4_096)
      let process = try ManagedStdioProcess(
        argv: [comSpecPath, "/d", "/s", "/c", "more"],
        workingDirectory: nil,
        environment: childEnvironment,
        mergeStandardError: false,
        onStandardOutput: { output.append($0) }
      )
      defer {
        if process.isRunning { _ = process.terminateAndWait() }
        process.close()
      }

      try process.writeStdin(Data("managed-stdio-round-trip\r\n".utf8))
      process.closeStdin()
      XCTAssertEqual(process.waitForExit(timeout: .seconds(5)), .exited(0))
      process.drainRemainingOutput()

      let captured = output.snapshot()
      XCTAssertTrue(captured.head.contains("managed-stdio-round-trip"))
    }

    func testManagedProcessDoesNotAllocateConsoleWindow() throws {
      guard FileManager.default.fileExists(atPath: powershellPath) else {
        throw XCTSkip("Windows PowerShell is unavailable")
      }
      let output = BoundedProcessOutputCollector(maximumBytes: 4_096)
      let process = try ManagedStdioProcess(
        argv: [
          powershellPath,
          "-NoLogo",
          "-NoProfile",
          "-NonInteractive",
          "-Command",
          """
          $ErrorActionPreference = 'Stop'
          Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class ConsoleProbe { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); }'
          [Console]::WriteLine([ConsoleProbe]::GetConsoleWindow().ToInt64())
          """,
        ],
        workingDirectory: nil,
        environment: childEnvironment,
        mergeStandardError: false,
        onStandardOutput: { output.append($0) }
      )
      defer {
        if process.isRunning { _ = process.terminateAndWait() }
        process.close()
      }

      XCTAssertEqual(process.waitForExit(timeout: .seconds(15)), .exited(0))
      process.drainRemainingOutput()

      let consoleHandle = output.snapshot().head.trimmingCharacters(in: .whitespacesAndNewlines)
      XCTAssertEqual(consoleHandle, "0")
    }

    func testBatchShimForwardsPercentStarArgumentsVerbatim() throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("managed-stdio batch-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }

      let probe = directory.appendingPathComponent("probe.ps1")
      let batch = directory.appendingPathComponent("forward.cmd")
      let probeSource = """
        $ErrorActionPreference = 'Stop'
        [Console]::Out.WriteLine((@($args) | ConvertTo-Json -Compress))
        """
      let batchSource = """
        @echo off
        "\(powershellPath)" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0probe.ps1" %*
        """
      try Data(probeSource.utf8).write(to: probe)
      try Data(batchSource.replacingOccurrences(of: "\n", with: "\r\n").utf8).write(to: batch)

      let expected = [
        "alpha beta",
        "quote\"value",
        "100%VAR%literal",
        "a&b|c<d>e^f!g",
        "quote\"&literal",
      ]
      let output = BoundedProcessOutputCollector(maximumBytes: 16 * 1_024)
      var environment = childEnvironment
      environment["VAR"] = "synthetic-expansion-must-not-appear"
      let process = try ManagedStdioProcess(
        argv: [batch.path] + expected,
        workingDirectory: directory.path,
        environment: environment,
        mergeStandardError: false,
        onStandardOutput: { output.append($0) }
      )
      defer {
        if process.isRunning { _ = process.terminateAndWait() }
        process.close()
      }

      XCTAssertEqual(process.waitForExit(timeout: .seconds(15)), .exited(0))
      process.drainRemainingOutput()

      let data = Data(output.snapshot().head.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
      let actual = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: data) as? [String]
      )
      XCTAssertEqual(actual, expected)
    }

    private var systemRoot: String {
      ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
    }

    private var comSpecPath: String {
      ProcessInfo.processInfo.environment["ComSpec"]
        ?? "\(systemRoot)\\System32\\cmd.exe"
    }

    private var powershellPath: String {
      let current = ProcessInfo.processInfo.environment
      let pwsh =
        current["CODEX_BRIDGE_TEST_PWSH"]
        ?? "\(current["ProgramFiles"] ?? "C:\\Program Files")\\PowerShell\\7\\pwsh.exe"
      if FileManager.default.fileExists(atPath: pwsh) { return pwsh }
      return "\(systemRoot)\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
    }

    private var childEnvironment: [String: String] {
      ProcessInfo.processInfo.environment
    }
  }
#endif

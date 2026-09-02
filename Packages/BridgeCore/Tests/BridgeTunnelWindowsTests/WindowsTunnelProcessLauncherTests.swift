import Crypto
import Foundation
import XCTest

@testable import BridgeTunnel

final class WindowsTunnelProcessLauncherTests: XCTestCase {
  private var runtimeDirectory: URL!

  override func setUpWithError() throws {
    runtimeDirectory = FileManager.default.temporaryDirectory.appending(
      path: "codexbridge-tunnel-launch-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: runtimeDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: runtimeDirectory.appendingPathComponent("codex-home"),
      withIntermediateDirectories: true
    )
  }

  override func tearDownWithError() throws {
    if let runtimeDirectory {
      try? FileManager.default.removeItem(at: runtimeDirectory)
    }
  }

  private static func cmdExecutable() throws -> URL {
    let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
    return URL(fileURLWithPath: systemRoot).appendingPathComponent("System32\\cmd.exe")
  }

  private static func verifiedCmd() throws -> TunnelVerifiedHelper {
    let executable = try cmdExecutable()
    let data = try Data(contentsOf: executable)
    return TunnelVerifiedHelper(
      executable: executable,
      codeIdentity: TunnelCodeIdentity(codeDirectoryHash: Data(SHA256.hash(data: data)))
    )
  }

  func testSpawnsAndCollectsOutputWithInjectedEnvironment() async throws {
    let key = "SECRET-KEY-VALUE-123"
    let launcher = TunnelProcessLauncher()
    let child = try launcher.spawn(
      verifiedHelper: try Self.verifiedCmd(),
      helperVerifier: TunnelHelperVerifier(),
      arguments: ["/c", "echo hello %CODEX_BRIDGE_TUNNEL_API_KEY%"],
      runtimeKey: Data(key.utf8),
      localMCPHeaderSecret: Data("token-token-token".utf8),
      runtimeDirectory: runtimeDirectory,
      sensitiveValues: [key],
      outputLimit: 64 * 1024
    )
    let exit = try await waitForExit(child, within: .seconds(10))
    XCTAssertEqual(exit.code, 0)
    let stdout = child.stdout.snapshot().text
    XCTAssertTrue(stdout.contains("hello"), "stdout was: \(stdout)")
    XCTAssertTrue(stdout.contains("<redacted>"), "stdout was: \(stdout)")
    XCTAssertFalse(stdout.contains(key), "stdout leaked the key: \(stdout)")
  }

  func testDynamicIdentityMismatchFailsSpawn() throws {
    let launcher = TunnelProcessLauncher()
    let wrongIdentity = TunnelVerifiedHelper(
      executable: try Self.cmdExecutable(),
      codeIdentity: TunnelCodeIdentity(codeDirectoryHash: Data(repeating: 0xAB, count: 32))
    )
    XCTAssertThrowsError(
      try launcher.spawn(
        verifiedHelper: wrongIdentity,
        helperVerifier: TunnelHelperVerifier(),
        arguments: ["/c", "exit 0"],
        runtimeKey: Data("key".utf8),
        localMCPHeaderSecret: Data("token".utf8),
        runtimeDirectory: runtimeDirectory,
        sensitiveValues: [],
        outputLimit: 64 * 1024
      )
    ) { error in
      XCTAssertEqual(error as? TunnelHelperError, .identityMismatch)
    }
  }

  func testBeginTerminationKillsRunningChild() async throws {
    let launcher = TunnelProcessLauncher()
    let child = try launcher.spawn(
      verifiedHelper: try Self.verifiedCmd(),
      helperVerifier: TunnelHelperVerifier(),
      arguments: ["/c", "ping -n 60 127.0.0.1"],
      runtimeKey: Data("key".utf8),
      localMCPHeaderSecret: Data("token".utf8),
      runtimeDirectory: runtimeDirectory,
      sensitiveValues: [],
      outputLimit: 64 * 1024
    )
    XCTAssertNil(child.pollExit())
    XCTAssertTrue(child.beginTermination())
    let exit = try await waitForExit(child, within: .seconds(10))
    XCTAssertNotNil(exit)
  }

  private func waitForExit(
    _ child: TunnelSpawnedProcess,
    within duration: Duration
  ) async throws -> TunnelChildExit {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: duration)
    while clock.now < deadline {
      if let exit = child.pollExit() { return exit }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw TunnelManagerError.processTimedOut
  }
}

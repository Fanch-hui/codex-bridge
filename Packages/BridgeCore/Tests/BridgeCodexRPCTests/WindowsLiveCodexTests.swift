#if os(Windows)
  import Foundation
  import XCTest

  @testable import BridgeCodexRPC

  final class WindowsLiveCodexTests: XCTestCase {
    func testInstalledCodexReturnsModelsThroughBridgeTransport() async throws {
      guard ProcessInfo.processInfo.environment["CODEX_BRIDGE_TEST_LIVE_CODEX"] == "1" else {
        throw XCTSkip("Set CODEX_BRIDGE_TEST_LIVE_CODEX=1 to use the installed Codex.")
      }
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let installation = AppServerConfiguration.codex()
      let keys = [
        "systemroot", "systemdrive", "comspec", "path", "pathext", "windir", "temp", "tmp",
      ]
      var environment = ProcessInfo.processInfo.environment.filter {
        keys.contains($0.key.lowercased())
      }
      environment["USERPROFILE"] = root.path
      let client = CodexAppServerClient(
        configuration: AppServerConfiguration(
          executableURL: installation.executableURL,
          arguments: installation.arguments,
          currentDirectoryURL: root,
          environment: CodexWindowsPath.childEnvironment(configured: environment, source: [:])
        ))
      do {
        let startedAt = Date()
        try await client.start()
        print("LIVE_CODEX_START_SECONDS=\(Date().timeIntervalSince(startedAt))")
        _ = try await client.initialize(clientInfo: .bridge(version: "0.3.0"))
        let catalog = try await client.listModels()
        print("LIVE_CODEX_CATALOG_SECONDS=\(Date().timeIntervalSince(startedAt))")
        XCTAssertFalse(catalog.data.isEmpty)
        print("LIVE_CODEX_MODEL_COUNT=\(catalog.data.count)")
      } catch {
        XCTFail("The installed Codex did not complete the Bridge model handshake: \(error)")
      }
      await client.stop()
    }
  }
#endif

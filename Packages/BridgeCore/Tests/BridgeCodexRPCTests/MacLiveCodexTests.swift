#if os(macOS)
  import Foundation
  import XCTest

  @testable import BridgeCodexRPC

  final class MacLiveCodexTests: XCTestCase {
    func testInstalledCodexReturnsModelsThroughBridgeTransport() async throws {
      try XCTSkipUnless(ProcessInfo.processInfo.environment["CODEX_BRIDGE_TEST_LIVE_CODEX"] == "1")
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let installation = AppServerConfiguration.codex()
      let client = CodexAppServerClient(
        configuration: AppServerConfiguration(
          executableURL: installation.executableURL, arguments: installation.arguments,
          currentDirectoryURL: root, environment: ProcessInfo.processInfo.environment))
      do {
        try await client.start()
        _ = try await client.initialize(clientInfo: .bridge(version: "1.2.0"))
        let catalog = try await client.listModels()
        XCTAssertFalse(catalog.data.isEmpty)
        print("LIVE_CODEX_MODEL_COUNT=\(catalog.data.count)")
      } catch {
        await client.stop()
        XCTFail("Installed Codex model handshake failed: \(String(describing: type(of: error)))")
        return
      }
      await client.stop()
    }
  }
#endif

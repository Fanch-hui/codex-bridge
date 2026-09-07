#if os(Windows)
  import BridgeCodexRPC
  import Foundation
  import XCTest

  final class WindowsLiveCodexTests: XCTestCase {
    func testInstalledCodexReturnsModelsThroughBridgeTransport() async throws {
      guard ProcessInfo.processInfo.environment["CODEX_BRIDGE_TEST_LIVE_CODEX"] == "1" else {
        throw XCTSkip("Set CODEX_BRIDGE_TEST_LIVE_CODEX=1 to use the installed Codex.")
      }
      let client = CodexAppServerClient()
      do {
        try await client.start()
        _ = try await client.initialize(clientInfo: .bridge(version: "0.3.0"))
        let catalog = try await client.listModels()
        XCTAssertFalse(catalog.data.isEmpty)
        print("LIVE_CODEX_MODEL_COUNT=\(catalog.data.count)")
      } catch {
        XCTFail("The installed Codex did not complete the Bridge model handshake.")
      }
      await client.stop()
    }
  }
#endif

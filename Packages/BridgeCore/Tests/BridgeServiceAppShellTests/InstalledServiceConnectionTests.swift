import BridgeIPC
import Foundation
import XCTest

final class InstalledServiceConnectionTests: XCTestCase {
  func testInstalledAgentsConnect() async throws {
    guard ProcessInfo.processInfo.environment["CODEX_BRIDGE_TEST_INSTALLED_AGENTS"] == "1" else {
      throw XCTSkip("Requires installed Antigravity and OpenCode agents.")
    }
    let client = BridgeServiceClient()
    do {
      for providerID in ["antigravity", "opencode"] {
        let installation = try await client.connectAgentInstallation(providerID: providerID)
        XCTAssertEqual(installation.availability, "available", providerID)
        XCTAssertTrue(installation.isEnabled, providerID)
      }
      await client.invalidate()
    } catch {
      await client.invalidate()
      throw error
    }
  }

  func testInstalledAgentDiscoveryDoesNotChangeRegistrations() async throws {
    guard ProcessInfo.processInfo.environment["CODEX_BRIDGE_TEST_INSTALLED_SERVICE"] == "1" else {
      throw XCTSkip("Requires the installed macOS service.")
    }
    let client = BridgeServiceClient()
    do {
      let before = try await client.agentCatalog()
      let after = try await client.agentCatalog(forceRefresh: true)
      XCTAssertFalse(after.providers.isEmpty)
      XCTAssertTrue(after.providers.allSatisfy { $0.discoveryState != nil })
      XCTAssertEqual(before.installations, after.installations)
      await client.invalidate()
    } catch {
      await client.invalidate()
      throw error
    }
  }

  func testInstalledServiceRespondsToConnectionQueries() async throws {
    guard ProcessInfo.processInfo.environment["CODEX_BRIDGE_TEST_INSTALLED_SERVICE"] == "1" else {
      throw XCTSkip("Requires the installed macOS service.")
    }
    let client = BridgeServiceClient()
    do {
      let status = try await client.status()
      let agents = try await client.agentCatalog()
      XCTAssertFalse(agents.providers.isEmpty)
      XCTAssertEqual(status.status.mcpState, "ready")
      let models = try await client.modelCatalog()
      XCTAssertFalse(models.models.isEmpty)
      await client.invalidate()
    } catch {
      await client.invalidate()
      throw error
    }
  }
}

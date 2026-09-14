import BridgeIPC
import BridgeServiceHost
import Foundation
import XCTest

final class DeepSeekHarnessMCPIPCTests: XCTestCase {
  func testMCPConfigurationRoundTripsWithoutReturningSecrets() async throws {
    let fixture = try await makeServiceHostFixture(self)
    let (client, listener) = xpcClient(composition: fixture.composition)
    defer {
      listener.invalidate()
      Task { await client.invalidate() }
    }
    let saved = try await client.saveDeepSeekHarnessMCPServer(
      .init(
        id: "fixture", name: "fixture", enabled: true, transport: "http",
        url: "https://example.test/mcp",
        headers: [.init(name: "Authorization", value: "Bearer fixture-secret")]
      ))
    XCTAssertEqual(saved.headers.first?.hasValue, true)
    let listed = try await client.deepSeekHarnessMCPServers()
    XCTAssertEqual(listed.servers.map(\.id), ["fixture"])
    let data = try JSONEncoder().encode(listed)
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fixture-secret"))
    try await client.deleteDeepSeekHarnessMCPServer(id: "fixture")
    let empty = try await client.deepSeekHarnessMCPServers()
    XCTAssertTrue(empty.servers.isEmpty)
  }
}

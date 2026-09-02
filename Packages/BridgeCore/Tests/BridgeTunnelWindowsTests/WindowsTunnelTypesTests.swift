import BridgeSecurity
import XCTest

@testable import BridgeTunnel

final class WindowsTunnelTypesTests: XCTestCase {
  func testConfigurationAcceptsWindowsAbsolutePaths() throws {
    let reference = try SecretReference(validating: "runtime-key.test")
    let digest = String(repeating: "a", count: 64)
    let mcpURL = URL(string: "http://127.0.0.1:4321/mcp/\(String(repeating: "A", count: 43))")!
    let helper = URL(fileURLWithPath: "C:\\Program Files\\CodexBridge\\tunnel-client.exe")
    let runtime = URL(
      fileURLWithPath: "C:\\Users\\tester\\AppData\\Local\\CodexBridgeService\\TunnelRuntime",
      isDirectory: true
    )
    XCTAssertNoThrow(
      try TunnelConfiguration(
        helperExecutable: helper,
        tunnelID: TunnelID(rawValue: "tunnel_abcdefghijklmnopqrstuvwxyz012345"),
        runtimeKeyReference: reference,
        localMCPURL: mcpURL,
        runtimeDirectory: runtime,
        expectedHelperSHA256: digest
      )
    )
  }

  func testConfigurationRejectsRelativeAndNetworkPaths() throws {
    let reference = try SecretReference(validating: "runtime-key.test")
    let digest = String(repeating: "a", count: 64)
    let mcpURL = URL(string: "http://127.0.0.1:4321/mcp/\(String(repeating: "A", count: 43))")!
    let invalidURLs: [URL] = [
      URL(fileURLWithPath: "\\\\server\\share\\tunnel-client.exe"),
      URL(string: "file:///tunnel-client.exe")!,
      URL(string: "file:///C:tunnel-client.exe")!,
    ]
    for invalid in invalidURLs {
      XCTAssertThrowsError(
        try TunnelConfiguration(
          helperExecutable: invalid,
          tunnelID: TunnelID(rawValue: "tunnel_abcdefghijklmnopqrstuvwxyz012345"),
          runtimeKeyReference: reference,
          localMCPURL: mcpURL,
          runtimeDirectory: URL(fileURLWithPath: "C:\\TunnelRuntime", isDirectory: true),
          expectedHelperSHA256: digest
        )
      )
    }
  }
}

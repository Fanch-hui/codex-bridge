import BridgeAgentCore
import Foundation
import XCTest

@testable import BridgeQoderSDK

final class QoderLiveContractTests: XCTestCase {
  func testInstalledCNRuntimeThroughSwiftProvider() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["CODEX_BRIDGE_TEST_LIVE_AGENTS"] == "1")
    let environment = ToolDiscoveryEnvironment.current()
    let cli = try XCTUnwrap(AgentExecutableResolver(environment: environment).resolve("qoderclicn"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = try QoderSDKProvider(
      configuration: .init(
        runtimeBaseDirectory: root.path, sourceEnvironment: environment))
    let installation = try AgentInstallation(
      id: AgentInstallationID(rawValue: "live-qoder-cn"), providerID: .qoder, executablePath: cli)
    let artifacts = try await provider.installationArtifacts(for: installation)
    XCTAssertEqual(artifacts.count, 4)
    let result = await provider.probe(try AgentProbeRequest(installation: installation))
    XCTAssertTrue(
      result.available || result.unavailableReason?.contains("登录") == true,
      result.unavailableReason ?? "Missing runtime result")
    print("LIVE_QODER_AUTHENTICATED=\(result.available)")
  }
}

import BridgeACP
import BridgeAgentCore
import Foundation
import XCTest

@testable import BridgeDeepSeekHarnessACP

final class DeepSeekHarnessACPLiveProbeTests: XCTestCase {
  func testInstalledCLIHandshakeAndModelCatalog() async throws {
    guard let executable = ProcessInfo.processInfo.environment["CODEX_BRIDGE_TEST_DSH_EXECUTABLE"]
    else { throw XCTSkip("Set CODEX_BRIDGE_TEST_DSH_EXECUTABLE to a built DSH CLI.") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = root.appendingPathComponent("cordis.yml")
    try DeepSeekHarnessACPProfile.bundledConfigurationTemplate().write(to: configuration)
    let environment = ["HOME": root.path, "PATH": "/opt/homebrew/opt/node@22/bin:/usr/bin:/bin"]
    let paths = try DeepSeekHarnessACPProfile.resolveArtifacts(
      executablePath: executable, configurationPath: configuration.path,
      sourceEnvironment: environment
    )
    let artifacts = try paths.map { role, path in
      let snapshot = try DeepSeekHarnessACPFileSnapshot(
        capturing: path, requiresExecutable: role.requiresExecutable
      )
      return AgentInstallationArtifact(
        role: role, canonicalPath: snapshot.path, device: snapshot.device,
        inode: snapshot.inode, fileSize: snapshot.fileSize,
        modificationTimeNanoseconds: snapshot.modificationTimeNanoseconds, sha256: snapshot.sha256
      )
    }
    let installation = try AgentInstallation(
      id: .init(rawValue: "live-dsh"), providerID: .deepSeekHarness,
      executablePath: executable, artifacts: artifacts
    )
    let provider = try DeepSeekHarnessACPProvider(
      configuration: .init(
        runtimeBaseDirectory: root.appendingPathComponent("runs").path,
        sourceEnvironment: environment
      ))
    let probe = await provider.probe(try .init(installation: installation, projectRoot: root.path))
    XCTAssertTrue(probe.available, probe.unavailableReason ?? "Probe failed")
    guard probe.available else { return }
    let models = try await provider.models(
      installation: probe.installation, projectRoot: root.path, selectedModelID: nil
    )
    XCTAssertFalse(models.isEmpty)
  }
}

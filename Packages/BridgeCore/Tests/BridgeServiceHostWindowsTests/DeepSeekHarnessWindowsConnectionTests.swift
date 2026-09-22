#if os(Windows)
  import BridgeAgentCore
  import BridgeDeepSeekHarnessACP
  import BridgeSecurity
  import BridgeServiceCore
  import Foundation
  import XCTest

  @testable import BridgeServiceHost

  final class DeepSeekHarnessWindowsConnectionTests: XCTestCase {
    func testOptInRealDSHArtifactsAndRegistrationCandidates() async throws {
      guard
        let executablePath = ProcessInfo.processInfo.environment[
          "CODEX_BRIDGE_TEST_DSH_EXECUTABLE"
        ]
      else {
        throw XCTSkip("Set CODEX_BRIDGE_TEST_DSH_EXECUTABLE to run the Windows DSH check.")
      }
      guard
        let fixtureParentPath = ProcessInfo.processInfo.environment[
          "CODEX_BRIDGE_TEST_DSH_FIXTURE_ROOT"
        ]
      else {
        throw XCTSkip("Set CODEX_BRIDGE_TEST_DSH_FIXTURE_ROOT to a D: fixture directory.")
      }

      let fixtureRoot = URL(fileURLWithPath: fixtureParentPath, isDirectory: true)
        .appendingPathComponent("dsh-connection-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(
        at: fixtureRoot,
        withIntermediateDirectories: true
      )
      defer { try? FileManager.default.removeItem(at: fixtureRoot) }

      let configuration = fixtureRoot.appendingPathComponent("cordis.yml")
      try DeepSeekHarnessACPProfile.bundledConfigurationTemplate().write(
        to: configuration,
        options: .atomic
      )

      var sourceEnvironment = ToolDiscoveryEnvironment.current()
      sourceEnvironment["CODEX_BRIDGE_DEEPSEEK_HARNESS_EXECUTABLE"] = executablePath
      let artifacts: [AgentInstallationArtifactRole: String]
      do {
        artifacts = try DeepSeekHarnessACPProfile.resolveArtifacts(
          executablePath: executablePath,
          configurationPath: configuration.path,
          sourceEnvironment: sourceEnvironment
        )
      } catch {
        XCTFail("resolveArtifacts failed: \(diagnostic(for: error))")
        return
      }

      XCTAssertEqual(
        Set(artifacts.keys),
        Set([
          .launchConfiguration,
          .runtimeManifest,
          .dependencyLock,
          .nodeInterpreter,
        ])
      )

      let dataPaths = try ServiceDataPaths.prepare(
        at: fixtureRoot.appendingPathComponent("service", isDirectory: true)
      )
      let requests = try ServiceAgentAutoDiscovery.registrationRequests(
        providerID: .deepSeekHarness,
        dataPaths: dataPaths,
        credentialsProvided: true,
        environment: sourceEnvironment,
        discoveredExecutablePath: executablePath
      )
      XCTAssertEqual(requests.count, 1)
      let request = try XCTUnwrap(requests.first)
      XCTAssertEqual(
        request.executablePath,
        try XCTUnwrap(AgentPathSemantics.canonicalPath(executablePath))
      )
      XCTAssertEqual(request.providerID, .deepSeekHarness)
      XCTAssertNotNil(request.configurationPath)
      XCTAssertEqual(
        Set(request.artifacts.map(\.role)),
        Set([.runtimeManifest, .dependencyLock, .nodeInterpreter])
      )

      let installationArtifacts = try artifacts.map { role, path in
        let snapshot = try SecureFileArtifactSnapshot(
          capturing: path,
          requiresExecutable: role.requiresExecutable
        )
        return AgentInstallationArtifact(
          role: role,
          canonicalPath: snapshot.canonicalPath,
          device: snapshot.device,
          inode: snapshot.inode,
          fileSize: snapshot.fileSize,
          modificationTimeNanoseconds: snapshot.modificationTimeNanoseconds,
          sha256: snapshot.sha256
        )
      }
      let installation = try AgentInstallation(
        id: AgentInstallationID(rawValue: "windows-real-dsh"),
        providerID: .deepSeekHarness,
        executablePath: executablePath,
        artifacts: installationArtifacts
      )
      let projectRoot = fixtureRoot.appendingPathComponent("project", isDirectory: true)
      try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
      var probeEnvironment = sourceEnvironment
      probeEnvironment["DEEPSEEK_API_KEY"] = "codex-bridge-test-fixture-key"
      probeEnvironment["DEEPSEEK_BASE_URL"] = "https://api.deepseek.com"
      probeEnvironment["DEEPSEEK_SEARCH_BASE_URL"] = "https://api.deepseek.com"
      let runtimeEnvironment = probeEnvironment
      let provider = try DeepSeekHarnessACPProvider(
        configuration: .init(
          runtimeBaseDirectory: fixtureRoot.appendingPathComponent("runtime").path,
          sourceEnvironment: sourceEnvironment,
          environmentProvider: { _ in runtimeEnvironment }
        )
      )
      let probe = await provider.probe(
        try AgentProbeRequest(installation: installation, projectRoot: projectRoot.path)
      )
      XCTAssertTrue(probe.available, probe.unavailableReason ?? "DSH probe failed")
    }

    private func diagnostic(for error: Error) -> String {
      guard let error = error as? DeepSeekHarnessACPError else {
        return String(describing: type(of: error))
      }
      switch error {
      case .artifactInvalid(let field): return "artifactInvalid(\(field))"
      case .nodeVersionIncompatible(let version):
        return "nodeVersionIncompatible(\(version))"
      case .remote(let code, _): return "remote(\(code))"
      default: return String(describing: error)
      }
    }

  }
#endif

import BridgeACP
import BridgeAgentCore
import Foundation
import XCTest

@testable import BridgeDeepSeekHarnessACP

final class DeepSeekHarnessACPLiveProbeTests: XCTestCase {
  func testInstalledCLIHandshakeAndModelCatalog() async throws {
    let fixture = try LiveDSHFixture()
    addTeardownBlock { fixture.remove() }
    let provider = try DeepSeekHarnessACPProvider(
      configuration: .init(
        runtimeBaseDirectory: fixture.root.appendingPathComponent("runs").path,
        sourceEnvironment: fixture.environment
      ))
    let probe = await provider.probe(
      try .init(
        installation: fixture.installation, projectRoot: fixture.root.path
      ))
    XCTAssertTrue(probe.available, probe.unavailableReason ?? "Probe failed")
    guard probe.available else { return }
    let models = try await provider.models(
      installation: probe.installation, projectRoot: fixture.root.path, selectedModelID: nil
    )
    XCTAssertFalse(models.isEmpty)
  }

  func testInstalledCLIRestoresSessionAndReconnectsConfiguredMCP() async throws {
    let fixture = try LiveDSHFixture()
    addTeardownBlock { fixture.remove() }
    let script = fixture.root.appendingPathComponent("mcp.mjs")
    try Data(Self.mcpScript.utf8).write(to: script)
    let first = try fixture.client(run: "first")
    addTeardownBlock { await first.shutdown() }
    let initialized: DeepSeekHarnessACPInitialization
    do {
      initialized = try await first.initialize()
    } catch {
      if let transport = await first.transport as? ACPProcessTransport {
        XCTFail(
          DeepSeekHarnessACPDiagnostic.sanitizeProviderMessage(
            transport.standardErrorSnapshot().tail))
      }
      throw error
    }
    XCTAssertTrue(initialized.supportsResumeSession)
    XCTAssertTrue(initialized.supportsMCPHTTP)
    let marker = fixture.root.appendingPathComponent("first-mcp.log")
    let servers = try fixture.mcp(script: script, marker: marker, initialization: initialized)
    let session = try await first.newSession(cwd: fixture.root.path, mcpServers: servers)
    await first.shutdown()
    XCTAssertTrue(try String(contentsOf: marker, encoding: .utf8).contains("tools/list"))

    let second = try fixture.client(run: "second")
    addTeardownBlock { await second.shutdown() }
    _ = try await second.initialize()
    let nextMarker = fixture.root.appendingPathComponent("second-mcp.log")
    let resumed = try await second.resumeSession(
      id: session.id, cwd: fixture.root.path,
      mcpServers: fixture.mcp(script: script, marker: nextMarker, initialization: initialized)
    )
    XCTAssertEqual(resumed.id, session.id)
    try await second.closeSession(id: resumed.id)
    await second.shutdown()
    XCTAssertTrue(try String(contentsOf: nextMarker, encoding: .utf8).contains("tools/list"))
  }

  private static let mcpScript = """
    import { createInterface } from 'node:readline';
    import { appendFileSync } from 'node:fs';
    createInterface({ input: process.stdin }).on('line', line => {
      const request = JSON.parse(line);
      if (request.id === undefined) return;
      appendFileSync(process.argv[2], request.method + '\\n');
      let result = {};
      if (request.method === 'initialize') result = {
        protocolVersion: request.params.protocolVersion,
        capabilities: { tools: {} }, serverInfo: { name: 'fixture', version: '1' }
      };
      if (request.method === 'tools/list') result = { tools: [{
        name: 'fixture_read', description: 'Read fixture data',
        inputSchema: { type: 'object', properties: {} }
      }] };
      process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result }) + '\\n');
    });
    """
}

private struct LiveDSHFixture {
  let root: URL
  let installation: AgentInstallation
  let environment: [String: String]

  init() throws {
    guard let executable = ProcessInfo.processInfo.environment["CODEX_BRIDGE_TEST_DSH_EXECUTABLE"]
    else { throw XCTSkip("Set CODEX_BRIDGE_TEST_DSH_EXECUTABLE to a built DSH CLI.") }
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let configuration = root.appendingPathComponent("cordis.yml")
    try DeepSeekHarnessACPProfile.bundledConfigurationTemplate().write(to: configuration)
    try Data("DEEPSEEK_BASE_URL=https://api.deepseek.com\nDEEPSEEK_API_KEY=fixture-only\n".utf8)
      .write(to: root.appendingPathComponent(".env"))
    environment = ["HOME": root.path, "PATH": "/opt/homebrew/opt/node@22/bin:/usr/bin:/bin"]
    let paths = try DeepSeekHarnessACPProfile.resolveArtifacts(
      executablePath: executable, configurationPath: configuration.path,
      sourceEnvironment: environment
    )
    let artifacts = try paths.map { role, path in
      let snapshot = try DeepSeekHarnessACPFileSnapshot(
        capturing: path, requiresExecutable: role.requiresExecutable)
      return AgentInstallationArtifact(
        role: role, canonicalPath: snapshot.path, device: snapshot.device, inode: snapshot.inode,
        fileSize: snapshot.fileSize,
        modificationTimeNanoseconds: snapshot.modificationTimeNanoseconds,
        sha256: snapshot.sha256
      )
    }
    installation = try .init(
      id: .init(rawValue: "live-dsh"), providerID: .deepSeekHarness,
      executablePath: executable, artifacts: artifacts
    )
  }

  func client(run: String) throws -> DeepSeekHarnessACPClient {
    let launch = try DeepSeekHarnessACPLaunchBuilder().make(
      installation: installation, projectRoot: root.path,
      runDirectory: root.appendingPathComponent(run).path,
      persistentStateDirectory: root.appendingPathComponent("state").path,
      networkAllowed: false, sourceEnvironment: environment
    )
    return DeepSeekHarnessACPClient(
      transport: try ACPProcessTransport.launch(configuration: launch.process),
      clientInfo: .init(name: "tests", title: "Tests", version: "1")
    )
  }

  func mcp(script: URL, marker: URL, initialization: DeepSeekHarnessACPInitialization) throws
    -> [ACPJSONValue]
  {
    let node = try XCTUnwrap(
      installation.artifacts.first { $0.role == .nodeInterpreter }?.canonicalPath)
    return try DeepSeekHarnessACPMCP.parameters(
      servers: [
        .init(
          id: "fixture", name: "fixture", transport: .stdio, command: node,
          args: [script.path, marker.path]
        )
      ], initialization: initialization, networkAllowed: false)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

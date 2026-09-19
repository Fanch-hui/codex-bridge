import BridgeAgentCore
import Crypto
import Darwin
import Foundation
import XCTest

@testable import BridgeDeepSeekHarnessACP

final class DeepSeekHarnessACPModernLaunchTests: XCTestCase {
  func testModernEntryUsesPackageIdentityAndLayout() throws {
    let fixture = try makeFixture(prefix: "modern-entry")
    addTeardownBlock { fixture.remove() }

    XCTAssertTrue(DeepSeekHarnessACPModernLaunch.isModernEntry(fixture.executable))
    let npmPackage = URL(fileURLWithPath: fixture.root)
      .appendingPathComponent("node_modules/@deepseek-ai/dsh", isDirectory: true)
    let npmLibrary = npmPackage.appendingPathComponent("lib", isDirectory: true)
    try FileManager.default.createDirectory(at: npmLibrary, withIntermediateDirectories: true)
    try Data("{\"name\":\"@deepseek-ai/dsh\",\"version\":\"0.1.5-rc.2\"}".utf8)
      .write(to: npmPackage.appendingPathComponent("package.json"))
    let npmEntry = npmLibrary.appendingPathComponent("bin.js").path
    try Data("// package entry\n".utf8).write(to: URL(fileURLWithPath: npmEntry))
    XCTAssertTrue(DeepSeekHarnessACPModernLaunch.isModernEntry(npmEntry))

    try Data("{\"name\":\"@deepseek-ai/other\"}".utf8).write(
      to: URL(fileURLWithPath: fixture.packageManifest)
    )
    XCTAssertFalse(DeepSeekHarnessACPModernLaunch.isModernEntry(fixture.executable))
  }

  func testModernLaunchUsesACPProfilePatchAndExternalConfigurationDirectory() throws {
    let fixture = try makeFixture(prefix: "modern-launch")
    let project = try makeDirectory(prefix: "modern-project")
    let run = try makeDirectory(prefix: "modern-run")
    let persistentState = try makeDirectory(prefix: "modern-persistent-state")
    addTeardownBlock {
      fixture.remove()
      try? FileManager.default.removeItem(atPath: project)
      try? FileManager.default.removeItem(atPath: run)
      try? FileManager.default.removeItem(atPath: persistentState)
    }

    let extended =
      try String(contentsOfFile: fixture.configuration, encoding: .utf8)
      + "\n- id: custom-tool\n  name: '@example/tool'\n"
    try Data(extended.utf8).write(to: URL(fileURLWithPath: fixture.configuration))
    let installation = try fixture.installation()
    let originalConfiguration = try Data(contentsOf: URL(fileURLWithPath: fixture.configuration))
    let launch = try DeepSeekHarnessACPLaunchBuilder().make(
      installation: installation,
      projectRoot: project,
      runDirectory: run,
      persistentStateDirectory: persistentState,
      modelID: "vendor/model-v2",
      catalogModelIDs: ["vendor/model-v2", "vendor/model-v3"],
      reasoningEffort: "high",
      mutationIntent: .workspaceWrite,
      networkAllowed: false,
      sourceEnvironment: [
        "HOME": project,
        "PATH": "/usr/bin:/bin",
        "HTTPS_PROXY": "http://127.0.0.1:7897",
        "no_proxy": "localhost,127.0.0.1",
      ]
    )

    XCTAssertEqual(
      launch.process.argv,
      [
        fixture.node,
        "--import",
        URL(fileURLWithPath: run).appendingPathComponent("profile-env.mjs").absoluteString,
        fixture.executable,
        "--profile",
        "acp",
        "--patch",
        launch.process.argv.last!,
      ]
    )
    XCTAssertEqual(
      URL(fileURLWithPath: launch.process.workingDirectory).standardizedFileURL.path,
      URL(fileURLWithPath: run).standardizedFileURL.path
    )
    let patch = try String(contentsOfFile: launch.process.argv.last!, encoding: .utf8)
    XCTAssertTrue(patch.contains("- id: llm-deepseek"))
    XCTAssertTrue(patch.contains("- insert:\n    - id: custom-tool\n      name: '@example/tool'"))
    XCTAssertTrue(patch.contains("reasoningEffort: \"high\""))
    XCTAssertTrue(patch.contains("model: \"vendor/model-v2\""))
    XCTAssertTrue(patch.contains("- id: \"vendor/model-v2\""))
    XCTAssertTrue(patch.contains("- id: \"vendor/model-v3\""))
    XCTAssertFalse(patch.contains("- id: \"deepseek-v4-pro\""))
    XCTAssertTrue(patch.contains("mode: workspace-write"))
    XCTAssertTrue(patch.contains("workspaceRoot: !!js process.env.DSH_WORKSPACE_ROOT"))
    XCTAssertTrue(patch.contains("- id: session-persistence-jsonl"))
    XCTAssertTrue(patch.contains("root: !!js process.env.DSH_SNAPSHOT_SESSIONS_ROOT"))
    XCTAssertFalse(patch.contains("DEEPSEEK_API_KEY"))
    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: fixture.configuration)),
      originalConfiguration
    )
    XCTAssertEqual(launch.process.environment["HTTPS_PROXY"], "http://127.0.0.1:7897")
    XCTAssertEqual(launch.process.environment["no_proxy"], "localhost,127.0.0.1")
    XCTAssertEqual(launch.process.environment["DSH_PERMISSION_MODE"], "workspace-write")
    XCTAssertTrue(launch.process.environment["DSH_HOME"]?.hasPrefix(run) == true)
    XCTAssertEqual(launch.process.environment["DSH_SNAPSHOT_SESSIONS_ROOT"], persistentState)
  }

  private func makeFixture(prefix: String) throws -> ModernFixture {
    let root = try makeDirectory(prefix: "\(prefix)-root")
    let external = try makeDirectory(prefix: "\(prefix)-profile")
    let app = URL(fileURLWithPath: root).appendingPathComponent("apps/cli/lib", isDirectory: true)
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    let packageManifest = URL(fileURLWithPath: root)
      .appendingPathComponent("apps/cli/package.json").path
    try Data("{\"name\":\"@deepseek-ai/dsh\",\"version\":\"99.0.0\"}".utf8)
      .write(to: URL(fileURLWithPath: packageManifest))
    try Data("{\"name\":\"dsh-workspace\"}".utf8)
      .write(to: URL(fileURLWithPath: root).appendingPathComponent("package.json"))
    try Data("lockfileVersion: '9.0'\n".utf8)
      .write(to: URL(fileURLWithPath: root).appendingPathComponent("pnpm-lock.yaml"))

    let node = URL(fileURLWithPath: root).appendingPathComponent("node").path
    try Data("#!/bin/sh\necho v22.19.0\n".utf8).write(to: URL(fileURLWithPath: node))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: node)
    let executable = app.appendingPathComponent("bin.js").path
    try Data("#!\(node)\n".utf8).write(to: URL(fileURLWithPath: executable))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable)

    let configuration = URL(fileURLWithPath: external).appendingPathComponent("cordis.yml").path
    try DeepSeekHarnessACPProfile.bundledConfigurationTemplate()
      .write(to: URL(fileURLWithPath: configuration))
    return ModernFixture(
      root: root,
      external: external,
      node: node,
      executable: executable,
      packageManifest: packageManifest,
      configuration: configuration
    )
  }

  private func makeDirectory(prefix: String) throws -> String {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(
      atPath: path,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    return path
  }
}

private struct ModernFixture {
  let root: String
  let external: String
  let node: String
  let executable: String
  let packageManifest: String
  let configuration: String

  func installation() throws -> AgentInstallation {
    let paths = try DeepSeekHarnessACPProfile.resolveArtifacts(
      executablePath: executable,
      configurationPath: configuration,
      sourceEnvironment: ["PATH": "/usr/bin:/bin"]
    )
    let artifacts = try paths.map { role, path in
      try artifact(role: role, path: path)
    }
    return try AgentInstallation(
      id: .init(rawValue: "modern-launch-fixture"),
      providerID: .deepSeekHarness,
      executablePath: executable,
      artifacts: artifacts
    )
  }

  func remove() {
    try? FileManager.default.removeItem(atPath: root)
    try? FileManager.default.removeItem(atPath: external)
  }
}

private func artifact(
  role: AgentInstallationArtifactRole,
  path: String
) throws -> AgentInstallationArtifact {
  var metadata = stat()
  guard lstat(path, &metadata) == 0 else { throw POSIXError(.ENOENT) }
  let data = try Data(contentsOf: URL(fileURLWithPath: path))
  let modificationTime =
    Int64(metadata.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(metadata.st_mtimespec.tv_nsec)
  return AgentInstallationArtifact(
    role: role,
    canonicalPath: path,
    device: UInt64(metadata.st_dev),
    inode: UInt64(metadata.st_ino),
    fileSize: UInt64(metadata.st_size),
    modificationTimeNanoseconds: modificationTime,
    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  )
}

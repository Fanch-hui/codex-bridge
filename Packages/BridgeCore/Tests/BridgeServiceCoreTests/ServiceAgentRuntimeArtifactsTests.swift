import BridgeAgentCore
import Foundation
import XCTest

@testable import BridgeServiceCore

final class ServiceAgentRuntimeArtifactsTests: XCTestCase {
  func testProviderArtifactsPersistAndReplacementRequiresReviewWhenDisabled() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let executable = fixture.rootURL.appendingPathComponent("pi")
    let runtime = fixture.rootURL.appendingPathComponent("runtime.json")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    try Data("{\"revision\":1}".utf8).write(to: runtime)
    let provider = try RuntimeArtifactProvider(path: runtime.path)
    let store = try SimpleServiceStore(path: fixture.databasePath)
    let registry = ServiceAgentRegistry(store: store, providers: [provider])
    let registered = try await registry.registerAndProbe(
      ServiceAgentRegistrationRequest(
        providerID: .pi, displayName: "Pi", executablePath: executable.path,
        trustProfile: .userTrusted, enableOnSuccess: false))
    XCTAssertEqual(registered.artifacts.count, 1)
    let saved = try await store.agentInstallation(id: registered.id)
    XCTAssertEqual(saved?.artifacts.map(\.identity), registered.artifacts.map(\.identity))
    XCTAssertEqual(saved?.artifacts.map(\.role), registered.artifacts.map(\.role))
    try Data("{\"revision\":2}".utf8).write(to: runtime)
    let review = try await registry.reprobe(installationID: registered.id)
    XCTAssertEqual(review.availability, .needsReview)
    let replaced = try await registry.reprobe(
      installationID: registered.id, acceptReplacement: true)
    XCTAssertEqual(replaced.availability, .available)
    XCTAssertNotEqual(
      replaced.artifacts.first?.identity.sha256, registered.artifacts.first?.identity.sha256)
  }
}

private struct RuntimeArtifactProvider: AgentProvider, AgentInstallationArtifactProviding {
  let descriptor: AgentProviderDescriptor
  let path: String

  init(path: String) throws {
    self.path = path
    descriptor = try AgentProviderDescriptor(providerID: .pi, displayName: "Pi", adapterRevision: 1)
  }

  func installationArtifacts(for installation: AgentInstallation) async throws
    -> [AgentInstallationArtifact]
  {
    let value = try ServiceAgentFileIdentity(capturing: path, requiresExecutable: false)
    return [
      AgentInstallationArtifact(
        role: .runtimeManifest, canonicalPath: value.canonicalPath,
        device: value.device, inode: value.inode, fileSize: value.fileSize,
        modificationTimeNanoseconds: value.modificationTimeNanoseconds, sha256: value.sha256)
    ]
  }

  func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
    let installation = try! AgentInstallation(
      id: request.installation.id, providerID: .pi,
      executablePath: request.installation.executablePath, version: "1.0.0",
      artifacts: request.installation.artifacts)
    return AgentProbeResult(installation: installation, available: true, capabilities: .empty)
  }

  func models(installation: AgentInstallation, projectRoot: String?) async throws
    -> [AgentModelDescriptor]
  { [] }

  func start(_ request: AgentExecutionRequest, installation: AgentInstallation) async throws
    -> AgentExecutionHandle
  {
    throw AgentRuntimeError.invalidRequest("fixture.execution")
  }
}

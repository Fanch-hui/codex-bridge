import BridgeAgentCore
import BridgeServiceCore
import Foundation
import XCTest

@testable import BridgeServiceHost

#if canImport(Darwin)
  import Darwin
#endif

final class ServiceAgentAutoDiscoveryTests: XCTestCase {
  func testDeepSeekDiscoveryReportsExecutableWithoutCreatingConfiguration() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "bridge-dsh-discovery-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("bin.js")
    try Data("#!/usr/bin/env node\n".utf8).write(to: executable)

    let summary = try ServiceAgentAutoDiscovery.discoverySummary(
      providerID: .deepSeekHarness,
      existingInstallations: [],
      environment: [
        "HOME": root.path,
        "PATH": "/empty",
        "DEEPSEEK_HARNESS_EXECUTABLE": executable.path,
      ]
    )

    XCTAssertEqual(summary.state, "discovered")
    XCTAssertEqual(summary.executablePath, executable.standardizedFileURL.path)
    XCTAssertNil(summary.configurationPath)
    XCTAssertTrue(summary.message?.contains("Base URL") == true)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("DeepSeekHarnessAuto").path
      )
    )
  }

  func testDiscoveryCatalogCachesUntilForcedRefresh() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "bridge-discovery-cache-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("deepseek-harness.js")
    try Data("#!/bin/sh\n".utf8).write(to: executable)

    let catalog = ServiceAgentDiscoveryCatalog(
      environment: [
        "HOME": root.path,
        "PATH": "/empty",
        "DEEPSEEK_HARNESS_EXECUTABLE": executable.path,
      ]
    )
    let first = await catalog.summaries(
      providerIDs: [.deepSeekHarness],
      existingInstallations: []
    )
    XCTAssertEqual(first[.deepSeekHarness]?.state, "discovered")

    try FileManager.default.removeItem(at: executable)
    let cached = await catalog.summaries(
      providerIDs: [.deepSeekHarness],
      existingInstallations: []
    )
    XCTAssertEqual(cached[.deepSeekHarness]?.state, "discovered")

    let refreshed = await catalog.summaries(
      providerIDs: [.deepSeekHarness],
      existingInstallations: [],
      forceRefresh: true
    )
    XCTAssertEqual(refreshed[.deepSeekHarness]?.state, "not_found")
  }

  func testOpenCodeDiscoveryKeepsAnExistingCustomPathAheadOfSearch() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "bridge-agent-discovery-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("custom-opencode")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    #if canImport(Darwin)
      XCTAssertEqual(chmod(executable.path, 0o700), 0)
    #endif
    let identity = try ServiceAgentExecutableIdentity(capturing: executable.path)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let existing = try ServiceAgentInstallationRecord(
      id: AgentInstallationID(rawValue: "ainst-existing"),
      providerID: .openCode,
      displayName: "OpenCode",
      executablePath: executable.path,
      executableIdentity: identity,
      version: nil,
      protocolRevision: nil,
      adapterRevision: 1,
      trustProfile: .managed,
      securityProfileID: AgentProfileID(rawValue: "controlled-readonly"),
      isEnabled: false,
      availability: .unavailable,
      capabilities: .empty,
      createdAt: now,
      updatedAt: now
    )
    let paths = ServiceDataPaths(
      rootURL: root,
      databaseURL: root.appendingPathComponent("service.sqlite"),
      supervisorScratchURL: root.appendingPathComponent("scratch"),
      tunnelRuntimeURL: root.appendingPathComponent("tunnel"),
      agentStateURL: root.appendingPathComponent("agent-state")
    )

    let requests = try ServiceAgentAutoDiscovery.registrationRequests(
      providerID: .openCode,
      dataPaths: paths,
      existingInstallations: [existing],
      environment: ["HOME": root.path, "PATH": "/empty"]
    )

    XCTAssertEqual(requests.first?.executablePath, identity.canonicalPath)
    XCTAssertEqual(requests.filter { $0.executablePath == identity.canonicalPath }.count, 1)
  }
}

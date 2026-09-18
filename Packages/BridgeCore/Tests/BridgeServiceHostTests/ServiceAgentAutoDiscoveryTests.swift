import BridgeAgentCore
import BridgeServiceApplication
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

  #if !os(Windows)
    func testDeepSeekDiscoveryFindsPATHSymlinkToBuiltEntry() throws {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-dsh-path-launcher-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      let sourceEntry = root.appendingPathComponent("source/apps/cli/lib/bin.js")
      let pathDirectory = root.appendingPathComponent("bin", isDirectory: true)
      let launcher = pathDirectory.appendingPathComponent("dsh")
      try FileManager.default.createDirectory(
        at: sourceEntry.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try FileManager.default.createDirectory(at: pathDirectory, withIntermediateDirectories: true)
      try Data("#!/usr/bin/env node\n".utf8).write(to: sourceEntry)
      try FileManager.default.createSymbolicLink(
        atPath: launcher.path,
        withDestinationPath: sourceEntry.path
      )
      defer { try? FileManager.default.removeItem(at: root) }

      let summary = try ServiceAgentAutoDiscovery.discoverySummary(
        providerID: .deepSeekHarness,
        existingInstallations: [],
        environment: ["HOME": "/empty", "PATH": pathDirectory.path]
      )

      XCTAssertEqual(summary.state, "discovered")
      XCTAssertEqual(summary.executablePath, sourceEntry.standardizedFileURL.path)
    }
  #endif

  #if os(Windows)
    func testDeepSeekDiscoveryFindsWindowsLauncherTarget() throws {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-dsh-windows-launcher-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      let sourceEntry = root.appendingPathComponent("source/apps/cli/lib/bin.js")
      let pathDirectory = root.appendingPathComponent("pnpm", isDirectory: true)
      let launcher = pathDirectory.appendingPathComponent("dsh.cmd")
      try FileManager.default.createDirectory(
        at: sourceEntry.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try FileManager.default.createDirectory(at: pathDirectory, withIntermediateDirectories: true)
      try Data("#!/usr/bin/env node\n".utf8).write(to: sourceEntry)
      try Data(
        "@echo off\r\nSET dp0=%~dp0\r\n\"%dp0%..\\source\\apps\\cli\\lib\\bin.js\" %*\r\n".utf8
      )
      .write(to: launcher)
      defer { try? FileManager.default.removeItem(at: root) }

      let summary = try ServiceAgentAutoDiscovery.discoverySummary(
        providerID: .deepSeekHarness,
        existingInstallations: [],
        environment: [
          "USERPROFILE": root.path,
          "PNPM_HOME": pathDirectory.path,
          "PATH": "C:\\empty",
        ]
      )

      XCTAssertEqual(summary.state, "discovered")
      XCTAssertEqual(summary.executablePath, sourceEntry.standardizedFileURL.path)
    }
  #endif

  func testDiscoveryPersistsAcrossRestartsUntilManualScan() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstEntry = root.appendingPathComponent("first.js")
    let secondEntry = root.appendingPathComponent("second.js")
    try Data("#!/usr/bin/env node\n".utf8).write(to: firstEntry)
    try Data("#!/usr/bin/env node\n".utf8).write(to: secondEntry)
    let cache = root.appendingPathComponent("discovered-agents.json")
    let initial = ServiceAgentDiscoveryCatalog(
      environment: ["DEEPSEEK_HARNESS_EXECUTABLE": firstEntry.path], cacheURL: cache
    )
    let first = await initial.summaries(providerIDs: [.deepSeekHarness], existingInstallations: [])
    XCTAssertEqual(first[.deepSeekHarness]?.executablePath, firstEntry.path)

    let restarted = ServiceAgentDiscoveryCatalog(
      environment: ["DEEPSEEK_HARNESS_EXECUTABLE": secondEntry.path], cacheURL: cache
    )
    let restored = await restarted.summaries(
      providerIDs: [.deepSeekHarness], existingInstallations: [])
    XCTAssertEqual(restored[.deepSeekHarness]?.executablePath, firstEntry.path)
    let scanned = await restarted.summaries(
      providerIDs: [.deepSeekHarness], existingInstallations: [], forceRefresh: true
    )
    XCTAssertEqual(scanned[.deepSeekHarness]?.executablePath, secondEntry.path)
    let persisted = ServiceAgentDiscoveryCache.load(from: cache)
    XCTAssertEqual(persisted?[.deepSeekHarness]?.executablePath, secondEntry.path)
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

  func testUpdatedInstallationResolutionFindsMovedExecutableAndPreservesProfile() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "bridge-agent-recovery-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let oldExecutable = root.appendingPathComponent("old-opencode")
    let newDirectory = root.appendingPathComponent(".opencode/bin", isDirectory: true)
    #if os(Windows)
      let newExecutable = newDirectory.appendingPathComponent("opencode.exe")
    #else
      let newExecutable = newDirectory.appendingPathComponent("opencode")
    #endif
    try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #if os(Windows)
      let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
      let command = URL(fileURLWithPath: systemRoot)
        .appendingPathComponent("System32")
        .appendingPathComponent("cmd.exe")
      try FileManager.default.copyItem(at: command, to: oldExecutable)
      try FileManager.default.copyItem(at: command, to: newExecutable)
    #else
      try Data("#!/bin/sh\nexit 0\n".utf8).write(to: oldExecutable)
      try Data("#!/bin/sh\nexit 0\n".utf8).write(to: newExecutable)
      #if canImport(Darwin)
        XCTAssertEqual(chmod(oldExecutable.path, 0o700), 0)
        XCTAssertEqual(chmod(newExecutable.path, 0o700), 0)
      #endif
    #endif
    let oldIdentity = try ServiceAgentExecutableIdentity(capturing: oldExecutable.path)
    try FileManager.default.removeItem(at: oldExecutable)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let existing = try ServiceAgentInstallationRecord(
      id: AgentInstallationID(rawValue: "ainst-recovery"),
      providerID: .openCode,
      displayName: "My OpenCode",
      executablePath: oldExecutable.path,
      executableIdentity: oldIdentity,
      version: "old",
      protocolRevision: "acp",
      adapterRevision: 1,
      trustProfile: .managed,
      securityProfileID: ServiceAgentProviderPolicyRegistry.controlledReadOnlyProfileID,
      isEnabled: true,
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

    let request = try ServiceAgentAutoDiscovery.updatedInstallationRequest(
      for: existing,
      dataPaths: paths,
      environment: ["HOME": root.path, "PATH": "/empty"]
    )

    XCTAssertEqual(request?.executablePath, newExecutable.standardizedFileURL.path)
    XCTAssertEqual(request?.displayName, existing.displayName)
    XCTAssertEqual(request?.trustProfile, existing.trustProfile)
    XCTAssertEqual(request?.securityProfileID, existing.securityProfileID)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("DeepSeekHarnessAuto").path
      )
    )
  }

  func testRecoveryDiscoveryDoesNotCreateDeepSeekConfiguration() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "bridge-dsh-recovery-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("bin.js")
    try Data("#!/usr/bin/env node\n".utf8).write(to: executable)
    let paths = ServiceDataPaths(
      rootURL: root,
      databaseURL: root.appendingPathComponent("service.sqlite"),
      supervisorScratchURL: root.appendingPathComponent("scratch"),
      tunnelRuntimeURL: root.appendingPathComponent("tunnel"),
      agentStateURL: root.appendingPathComponent("agent-state")
    )

    let requests = try ServiceAgentAutoDiscovery.registrationRequests(
      providerID: .deepSeekHarness,
      dataPaths: paths,
      environment: [
        "HOME": root.path,
        "PATH": "/empty",
        "DEEPSEEK_HARNESS_EXECUTABLE": executable.path,
      ],
      allowGeneratedConfiguration: false
    )

    XCTAssertTrue(requests.isEmpty)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: paths.agentStateURL.appendingPathComponent("DeepSeekHarnessAuto").path
      )
    )
  }
}

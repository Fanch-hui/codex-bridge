import BridgeAgentCore
import BridgeServiceCore
import Foundation
import XCTest

@testable import BridgeServiceHost

#if canImport(Darwin)
  import Darwin
#endif

final class ServiceAgentAutoDiscoveryTests: XCTestCase {
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

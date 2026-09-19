import BridgeServiceCore
import Foundation
import XCTest

@testable import BridgeServiceHost

final class ServiceAgentConnectionPreparationTests: XCTestCase {
  func testDiscoveredDeepSeekEntryReportsValidationFailureInsteadOfMissingInstallation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let entry = root.appendingPathComponent("bin.js")
    try Data("#!/usr/bin/env node\n".utf8).write(to: entry)
    let paths = ServiceDataPaths(
      rootURL: root,
      databaseURL: root.appendingPathComponent("service.sqlite"),
      supervisorScratchURL: root.appendingPathComponent("scratch"),
      tunnelRuntimeURL: root.appendingPathComponent("tunnel"),
      agentStateURL: root.appendingPathComponent("agent-state")
    )

    XCTAssertThrowsError(
      try ServiceAgentAutoDiscovery.registrationRequests(
        providerID: .deepSeekHarness,
        dataPaths: paths,
        credentialsProvided: true,
        environment: ["HOME": root.path, "PATH": "/empty"],
        discoveredExecutablePath: entry.path
      )
    ) { error in
      let response = BridgeServiceRequestController.map(error)
      XCTAssertEqual(response.code, "agent_artifact_invalid")
      XCTAssertTrue(response.message.contains("source_root"))
    }
  }
}

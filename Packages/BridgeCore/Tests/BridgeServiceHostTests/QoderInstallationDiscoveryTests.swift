import BridgeAgentCore
import Foundation
import XCTest

@testable import BridgeServiceHost

final class QoderInstallationDiscoveryTests: XCTestCase {
  func testLiveInstalledPiAndQoderDiscoveryWhenRequested() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["CODEX_BRIDGE_TEST_LIVE_AGENTS"] == "1")
    for providerID in [AgentProviderID.pi, .qoder] {
      let summary = try ServiceAgentAutoDiscovery.discoverySummary(
        providerID: providerID, existingInstallations: [],
        environment: ToolDiscoveryEnvironment.current())
      XCTAssertEqual(summary.state, "discovered", providerID.rawValue)
      XCTAssertNotNil(summary.executablePath)
    }
    let qoder = try ServiceAgentAutoDiscovery.qoderRequests(
      existingPaths: [], environment: ToolDiscoveryEnvironment.current(), distribution: .cn)
    XCTAssertTrue(qoder.contains { $0.executablePath.hasSuffix("qoderclicn.js") })
  }

  func testOfficialNPMWrapperResolvesToRegionalCLIEntry() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for (region, package, command) in [
      (QoderDistribution.cn, "@qodercn-ai/qoderclicn", "qoderclicn"),
      (.international, "@qoder-ai/qodercli", "qodercli"),
    ] {
      let prefix = root.appendingPathComponent(region.rawValue)
      let packageDirectory = region == .cn ? "node_modules/" : "global/5/node_modules/"
      let packageRoot = prefix.appendingPathComponent(packageDirectory + package)
      let entry = packageRoot.appendingPathComponent("bundle/" + command + ".js")
      try FileManager.default.createDirectory(
        at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("#!/usr/bin/env node\n".utf8).write(to: entry)
      let manifest = try JSONSerialization.data(withJSONObject: [
        "name": package, "bin": [command: "bundle/" + command + ".js"],
      ])
      try manifest.write(to: packageRoot.appendingPathComponent("package.json"))
      let wrapper = prefix.appendingPathComponent(command + ".cmd")
      try Data("@echo off\n".utf8).write(to: wrapper)
      let actual = try ServiceAgentAutoDiscovery.qoderExecutablePath(
        wrapper.path, distribution: region)
      XCTAssertEqual(actual, AgentPathSemantics.canonicalPath(entry.resolvingSymlinksInPath().path))
      let candidates = try ServiceAgentAutoDiscovery.qoderRequests(
        existingPaths: [actual], environment: [:], allowInstallationSearch: false,
        distribution: region)
      XCTAssertEqual(candidates.map(\.executablePath), [actual])
    }
  }

  #if !os(Windows)
    func testCNAndInternationalAliasesStaySeparatedAndDeduplicate() throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let bin = root.appendingPathComponent(".local/bin")
      try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
      for (package, command, alias) in [
        ("@qodercn-ai/qoderclicn", "qoderclicn", "qodercn"),
        ("@qoder-ai/qodercli", "qodercli", "qoder"),
      ] {
        let packageRoot = root.appendingPathComponent(".local/lib/node_modules/" + package)
        let entry = packageRoot.appendingPathComponent("bundle/" + command + ".js")
        try FileManager.default.createDirectory(
          at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env node\n".utf8).write(to: entry)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: entry.path)
        for name in [command, alias] {
          try FileManager.default.createSymbolicLink(
            at: bin.appendingPathComponent(name), withDestinationURL: entry)
        }
      }
      let values = try ServiceAgentAutoDiscovery.qoderRequests(
        existingPaths: [], environment: ["HOME": root.path, "PATH": bin.path])
      XCTAssertEqual(values.count, 2)
      XCTAssertEqual(
        values.map { QoderDistribution.identify(executablePath: $0.executablePath) },
        [.cn, .international])
    }
  #endif
}

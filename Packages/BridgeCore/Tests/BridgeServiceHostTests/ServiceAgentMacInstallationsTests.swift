import Foundation
import XCTest

@testable import BridgeServiceHost

final class ServiceAgentMacInstallationsTests: XCTestCase {
  func testSearchDirectoriesIncludesUserToolchainsAndEnumeratesNodeVersions() throws {
    #if os(macOS)
      let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-mac-agent-search-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      let nvmBin = root.appendingPathComponent(".nvm/versions/node/v22.19.0/bin")
      let fnmBin = root.appendingPathComponent(
        "Library/Application Support/fnm/node-versions/v24.0.0/installation/bin"
      )
      try FileManager.default.createDirectory(at: nvmBin, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: fnmBin, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }

      let npmPrefix = root.appendingPathComponent("custom-npm")
      let pnpmHome = root.appendingPathComponent("custom-pnpm")
      let directories = Set(
        ServiceAgentAutoDiscovery.macOSAgentSearchDirectories(
          environment: [
            "HOME": root.path,
            "PATH": "/usr/bin",
            "NPM_CONFIG_PREFIX": npmPrefix.path,
            "PNPM_HOME": pnpmHome.path,
          ]
        )
      )

      XCTAssertTrue(directories.contains(nvmBin.path))
      XCTAssertTrue(directories.contains(fnmBin.path))
      XCTAssertTrue(directories.contains(pnpmHome.path))
      XCTAssertTrue(directories.contains(npmPrefix.appendingPathComponent("bin").path))
      XCTAssertTrue(directories.contains(root.appendingPathComponent(".bun/bin").path))
      XCTAssertFalse(directories.contains("/usr/bin"))
    #endif
  }

}

#if os(Windows)
  import BridgeAgentCore
  import BridgeServiceCore
  import Foundation
  import XCTest

  @testable import BridgeServiceHost

  final class ServiceAgentWindowsDiscoveryTests: XCTestCase {
    func testUserInstallDirectoryFindsOpenCodeLauncherWithoutPATH() throws {
      let root = temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let directory =
        root
        .appendingPathComponent("Programs")
        .appendingPathComponent("OpenCode")
        .appendingPathComponent("bin")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let launcher = directory.appendingPathComponent("opencode.cmd")
      try Data("@echo off\r\n".utf8).write(to: launcher)

      let requests = try ServiceAgentAutoDiscovery.commandLineRequests(
        providerID: .openCode,
        names: ["opencode"],
        displayName: "OpenCode",
        trustProfile: .managed,
        securityProfileID: AgentProfileID(rawValue: "controlled-readonly"),
        existingPaths: [],
        environment: [
          "USERPROFILE": root.path,
          "LOCALAPPDATA": root.path,
          "PATH": #"C:\empty"#,
        ]
      )

      XCTAssertEqual(requests.map(\.executablePath), [launcher.standardizedFileURL.path])
    }

    func testPackageManagerHomeFindsAntigravityLauncherWithoutPATH() throws {
      let root = temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let directory = root.appendingPathComponent("pnpm")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let launcher = directory.appendingPathComponent("agy.cmd")
      try Data("@echo off\r\n".utf8).write(to: launcher)

      let requests = try ServiceAgentAutoDiscovery.commandLineRequests(
        providerID: .antigravity,
        names: ["agy", "antigravity"],
        displayName: "Antigravity",
        trustProfile: .userTrusted,
        securityProfileID: AgentProfileID(rawValue: "desktop-shared"),
        existingPaths: [],
        environment: [
          "USERPROFILE": root.path,
          "LOCALAPPDATA": root.path,
          "PNPM_HOME": directory.path,
          "PATH": #"C:\empty"#,
        ]
      )

      XCTAssertEqual(requests.map(\.executablePath), [launcher.standardizedFileURL.path])
    }

    func testExplicitPathSkipsInstallationSearch() throws {
      let root = temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let explicitDirectory = root.appendingPathComponent("explicit")
      let standardDirectory =
        root
        .appendingPathComponent("Programs")
        .appendingPathComponent("OpenCode")
        .appendingPathComponent("bin")
      try FileManager.default.createDirectory(
        at: explicitDirectory, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: standardDirectory, withIntermediateDirectories: true)
      let explicitLauncher = explicitDirectory.appendingPathComponent("opencode.cmd")
      let standardLauncher = standardDirectory.appendingPathComponent("opencode.cmd")
      try Data("@echo off\r\n".utf8).write(to: explicitLauncher)
      try Data("@echo off\r\n".utf8).write(to: standardLauncher)

      let requests = try ServiceAgentAutoDiscovery.commandLineRequests(
        providerID: .openCode,
        names: ["opencode"],
        displayName: "OpenCode",
        trustProfile: .managed,
        securityProfileID: AgentProfileID(rawValue: "controlled-readonly"),
        existingPaths: [explicitLauncher.path],
        environment: [
          "USERPROFILE": root.path,
          "LOCALAPPDATA": root.path,
          "PATH": #"C:\empty"#,
        ],
        allowInstallationSearch: false
      )

      XCTAssertEqual(requests.map(\.executablePath), [explicitLauncher.standardizedFileURL.path])
    }

    func testRegistryLocationsPreserveSpacesAndIconSuffix() {
      XCTAssertEqual(
        ServiceAgentWindowsInstallationSources.installationPath(#"D:\Agent Apps\OpenCode"#),
        #"D:\Agent Apps\OpenCode"#
      )
      XCTAssertEqual(
        ServiceAgentWindowsInstallationSources.installationPath(
          #""D:\Agent Apps\OpenCode\OpenCode.exe",0"#
        ),
        #"D:\Agent Apps\OpenCode\OpenCode.exe"#
      )
    }

    private func temporaryRoot() -> URL {
      FileManager.default.temporaryDirectory.appending(
        path: "bridge-agent-windows-discovery-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    }
  }
#endif

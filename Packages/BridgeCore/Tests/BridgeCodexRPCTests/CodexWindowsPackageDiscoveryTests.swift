#if os(Windows)
  import Foundation
  import XCTest

  @testable import BridgeCodexRPC

  final class CodexWindowsPackageDiscoveryTests: XCTestCase {
    func testPackagedInstallationSelectsBundledCLI() throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let app = root.appendingPathComponent("app")
      let resources = app.appendingPathComponent("resources")
      try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
      let cli = resources.appendingPathComponent("codex.exe")
      try executableHeader().write(to: cli)
      try executableHeader().write(to: app.appendingPathComponent("Codex.exe"))
      let environment = Dictionary(
        uniqueKeysWithValues: [
          "USERPROFILE", "APPDATA", "LOCALAPPDATA", "ProgramFiles", "ProgramW6432", "PATH",
        ]
        .map { ($0, root.path) })
      let resolver = CodexExecutableResolver(
        packagedInstallations: { [root.path] }, environment: environment)

      XCTAssertTrue(CodexWindowsPath.equivalent(try XCTUnwrap(resolver.resolve()), cli.path))
    }

    func testRegisteredStoreCodexIsDiscovered() throws {
      guard ProcessInfo.processInfo.environment["CODEX_BRIDGE_TEST_LIVE_CODEX"] == "1" else {
        throw XCTSkip("Set CODEX_BRIDGE_TEST_LIVE_CODEX=1 to use the installed Codex.")
      }
      let roots = CodexWindowsPackageDiscovery.installationDirectories()
      guard !roots.isEmpty else { throw XCTSkip("The Codex Store package is not installed.") }
      let executable = AppServerConfiguration.codex().executableURL.path
      XCTAssertTrue(
        roots.contains {
          CodexWindowsPath.equivalent(
            executable, CodexWindowsPath.join($0, "app", "resources", "codex.exe"))
        })
    }

    private func executableHeader() -> Data {
      let machine: UInt16
      switch CodexWindowsArchitecture.current {
      case .arm64: machine = 0xAA64
      case .amd64: machine = 0x8664
      }
      var bytes = [UInt8](repeating: 0, count: 512)
      bytes[0] = 0x4D
      bytes[1] = 0x5A
      bytes[0x3C] = 0x80
      bytes[0x80] = 0x50
      bytes[0x81] = 0x45
      bytes[0x84] = UInt8(machine & 0xFF)
      bytes[0x85] = UInt8(machine >> 8)
      bytes[0x96] = 0x02
      return Data(bytes)
    }
  }
#endif

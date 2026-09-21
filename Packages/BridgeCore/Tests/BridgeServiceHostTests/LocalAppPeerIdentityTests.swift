#if os(macOS)
  import Foundation
  import XCTest
  @testable import BridgeServiceHost

  final class LocalAppPeerIdentityTests: XCTestCase {
    func testSignedAppBundleAtTheServiceInstallationIsAccepted() throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let app = root.appendingPathComponent("CodexBridge.app")
      let contents = app.appendingPathComponent("Contents")
      let executable = contents.appendingPathComponent("MacOS/CodexBridge")
      try FileManager.default.createDirectory(
        at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
      let info = try PropertyListSerialization.data(
        fromPropertyList: [
          "CFBundleIdentifier": "org.codexbridge.peer-test",
          "CFBundleExecutable": "CodexBridge", "CFBundlePackageType": "APPL",
        ],
        format: .xml, options: 0)
      try info.write(to: contents.appendingPathComponent("Info.plist"))
      let signer = Process()
      signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
      signer.arguments = ["--force", "--sign", "-", app.path]
      signer.standardError = FileHandle.nullDevice
      try signer.run()
      signer.waitUntilExit()
      XCTAssertEqual(signer.terminationStatus, 0)
      let process = Process()
      process.executableURL = executable
      process.arguments = ["30"]
      try process.run()
      defer {
        process.terminate()
        process.waitUntilExit()
      }
      let service = contents.appendingPathComponent("Library/LaunchAgents/codex-bridge-service")
      XCTAssertTrue(
        LocalAppPeerIdentity.accepts(
          processID: process.processIdentifier, serviceExecutableURL: service))
      XCTAssertFalse(
        LocalAppPeerIdentity.accepts(
          processID: process.processIdentifier,
          serviceExecutableURL: root.appendingPathComponent("other/codex-bridge-service")))
    }

    func testSameUserProcessIsNotAutomaticallyTrustedAsDesktopApp() {
      XCTAssertFalse(
        LocalAppPeerIdentity.accepts(processID: ProcessInfo.processInfo.processIdentifier))
      XCTAssertFalse(LocalAppPeerIdentity.accepts(processID: 0))
    }
  }
#endif

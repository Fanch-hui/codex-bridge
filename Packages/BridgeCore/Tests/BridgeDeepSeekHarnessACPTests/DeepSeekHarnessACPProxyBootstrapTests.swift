import Foundation
import XCTest

@testable import BridgeDeepSeekHarnessACP

final class DeepSeekHarnessACPProxyBootstrapTests: XCTestCase {
  func testProfileProxyLoadsBeforeEntryAndRespectsLaunchingEnvironment() throws {
    #if os(macOS)
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      try Data("https_proxy=http://127.0.0.1:7897\nNO_PROXY=localhost\n".utf8)
        .write(to: root.appendingPathComponent(".env"))
      let bootstrap = try DeepSeekHarnessACPProfileBootstrap.prepare(
        configurationDirectory: root.path, runDirectory: root.path)
      for inherited in [false, true] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
        if inherited { environment["HTTPS_PROXY"] = "http://127.0.0.1:8888" }
        process.environment = environment
        let assertion =
          inherited
          ? "if (process.env.https_proxy !== undefined || process.env.HTTPS_PROXY !== 'http://127.0.0.1:8888') process.exit(1);"
          : "if (process.env.https_proxy !== 'http://127.0.0.1:7897') process.exit(1);"
        process.arguments = ["node", "--import", bootstrap, "-e", assertion]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
      }
    #else
      throw XCTSkip("The Node bootstrap fixture uses the macOS test runner.")
    #endif
  }
}

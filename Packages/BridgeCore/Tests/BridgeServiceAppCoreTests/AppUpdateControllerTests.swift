import Foundation
import XCTest

@testable import BridgeServiceAppCore

final class AppUpdateControllerTests: XCTestCase, @unchecked Sendable {
  func testStartupChecksOnceAndManualCheckCanRepeat() async {
    let client = UpdateClientFixture()
    let available = expectation(description: "startup result")
    let controller = await MainActor.run {
      let controller = makeController(client: client)
      controller.onChange = { if $0.phase == "available" { available.fulfill() } }
      controller.start()
      controller.start()
      return controller
    }
    await fulfillment(of: [available], timeout: 3)
    let manual = expectation(description: "manual result")
    await MainActor.run {
      controller.start()
      controller.onChange = { if $0.phase == "available" { manual.fulfill() } }
      controller.check()
    }
    await fulfillment(of: [manual], timeout: 3)
    let checks = await client.checks
    XCTAssertEqual(checks, 2)
  }

  func testInstallWaitsForAdmissionAndHandsOffPreparedPackage() async {
    let client = UpdateClientFixture()
    let available = expectation(description: "available")
    let waiting = expectation(description: "waiting")
    let installed = expectation(description: "installed")
    let lifecycle = await MainActor.run { InstallationFixture() }
    let controller = await MainActor.run {
      let controller = AppUpdateController(
        currentVersion: "1.0.0", platform: "macos", architecture: "arm64", kind: "app",
        client: client,
        preparePackage: { url, _ in
          lifecycle.package = url
          XCTAssertEqual(try Data(contentsOf: url), Data("package".utf8))
        },
        acquireInstallation: { lifecycle.isIdle },
        installPackage: {
          XCTAssertNotNil(lifecycle.package)
          lifecycle.didInstall = true
          installed.fulfill()
        },
        cancelInstallation: {})
      var lastPhase = "idle"
      controller.onChange = { state in
        guard state.phase != lastPhase else { return }
        lastPhase = state.phase
        if state.phase == "available" { available.fulfill() }
        if state.phase == "waiting" { waiting.fulfill() }
      }
      controller.start()
      return controller
    }
    await fulfillment(of: [available], timeout: 3)
    await MainActor.run {
      controller.install()
      controller.install()
    }
    await fulfillment(of: [waiting], timeout: 3)
    await MainActor.run {
      XCTAssertFalse(lifecycle.didInstall)
      lifecycle.isIdle = true
    }
    await fulfillment(of: [installed], timeout: 5)
    let downloads = await client.downloads
    XCTAssertEqual(downloads, 1)
    await MainActor.run {
      if let package = lifecycle.package {
        try? FileManager.default.removeItem(at: package.deletingLastPathComponent())
      }
    }
  }

  @MainActor
  private func makeController(client: UpdateClientFixture) -> AppUpdateController {
    AppUpdateController(
      currentVersion: "1.0.0", platform: "macos", architecture: "arm64", kind: "app",
      client: client, preparePackage: { _, _ in }, acquireInstallation: { true },
      installPackage: {}, cancelInstallation: {})
  }
}

@MainActor
private final class InstallationFixture {
  var isIdle = false
  var didInstall = false
  var package: URL?
}

private actor UpdateClientFixture: AppUpdateClientProtocol {
  var checks = 0
  var downloads = 0

  func check(currentVersion: String, platform: String, architecture: String, kind: String)
    async throws -> AppUpdateRelease?
  {
    checks += 1
    let asset = AppUpdateAsset(
      platform: platform, architecture: architecture, kind: kind,
      url: URL(
        string: "https://github.com/yeyuancc0-glitch/codex-bridge/releases/download/v1.1.0/app.zip")!,
      sha256: String(repeating: "0", count: 64), size: 7)
    return AppUpdateRelease(
      manifest: AppUpdateManifest(version: "1.1.0", notes: "更新", assets: [asset]), asset: asset)
  }

  func download(_ release: AppUpdateRelease, progress: @escaping @Sendable (Double) -> Void)
    async throws -> URL
  {
    downloads += 1
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("app.zip")
    try Data("package".utf8).write(to: url)
    progress(1)
    return url
  }
}

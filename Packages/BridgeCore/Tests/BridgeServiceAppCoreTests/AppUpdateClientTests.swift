import Foundation
import XCTest

@testable import BridgeServiceAppCore

final class AppUpdateClientTests: XCTestCase {
  func testSelectsOnlyNewerExactAsset() throws {
    let manifest = AppUpdateManifest(
      version: "1.10.0",
      notes: "更新",
      assets: [
        asset(platform: "macos", architecture: "arm64", kind: "app", name: "arm.zip"),
        asset(platform: "macos", architecture: "x64", kind: "app", name: "x64.zip"),
      ])

    let release = try AppUpdateClient.selectRelease(
      manifest: manifest,
      currentVersion: "1.9.9",
      platform: "macos",
      architecture: "arm64",
      kind: "app"
    )

    XCTAssertEqual(release?.asset.architecture, "arm64")
    XCTAssertNil(
      try AppUpdateClient.selectRelease(
        manifest: manifest,
        currentVersion: "1.10.0",
        platform: "macos",
        architecture: "arm64",
        kind: "app"
      ))
    XCTAssertThrowsError(
      try AppUpdateClient.selectRelease(
        manifest: manifest,
        currentVersion: "1.9.9",
        platform: "macos",
        architecture: "x86_64",
        kind: "app"
      )
    ) { error in
      XCTAssertEqual(error as? AppUpdateError, .noMatchingAsset)
    }
  }

  func testRejectsPreReleaseAndMalformedVersions() {
    XCTAssertThrowsError(
      try AppUpdateClient.selectRelease(
        manifest: AppUpdateManifest(
          version: "2.0.0-beta",
          notes: "",
          assets: [asset(platform: "macos", architecture: "arm64", kind: "app", name: "app.zip")]
        ),
        currentVersion: "1.0.0",
        platform: "macos",
        architecture: "arm64",
        kind: "app"
      )
    ) { error in
      XCTAssertEqual(error as? AppUpdateError, .invalidVersion("2.0.0-beta"))
    }
    XCTAssertThrowsError(
      try AppUpdateClient.selectRelease(
        manifest: AppUpdateManifest(
          version: "1.0",
          notes: "",
          assets: [asset(platform: "macos", architecture: "arm64", kind: "app", name: "app.zip")]
        ),
        currentVersion: "1.0.0",
        platform: "macos",
        architecture: "arm64",
        kind: "app"
      ))
  }

  func testValidatesDownloadedFileSizeAndDigest() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AppUpdateClientTests-\(UUID().uuidString)", isDirectory: true)
    let file = directory.appendingPathComponent("package.zip")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data("payload".utf8)))

    XCTAssertNoThrow(
      try AppUpdateIntegrity.validate(
        fileURL: file,
        expectedSize: 7,
        expectedDigest: "239f59ed55e737c77147cf55ad0c1b030b6d7ee748a7426952f9b852d5a935e5"
      ))
    XCTAssertThrowsError(
      try AppUpdateIntegrity.validate(
        fileURL: file,
        expectedSize: 6,
        expectedDigest: "239f59ed55e737c77147cf55ad0c1b030b6d7ee748a7426952f9b852d5a935e5"
      )
    ) { error in
      XCTAssertEqual(error as? AppUpdateError, .sizeMismatch(expected: 6, actual: 7))
    }
  }

  private func asset(platform: String, architecture: String, kind: String, name: String)
    -> AppUpdateAsset
  {
    AppUpdateAsset(
      platform: platform,
      architecture: architecture,
      kind: kind,
      url: URL(
        string: "https://github.com/yeyuancc0-glitch/codex-bridge/releases/download/v1.0.0/\(name)")!,
      sha256: "239f59ed55e737c77147cf55ad0c1b030b6d7ee748a7426952f9b852d5a935e5",
      size: 7
    )
  }
}

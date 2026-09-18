#if !os(Windows)
  import Foundation
  import XCTest

  @testable import BridgeCodexRPC

  final class CodexMacExecutableResolverTests: XCTestCase {
    func testResolvesUserCodexAppBundleBeforePackageManagers() throws {
      let root = try makeTemporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let bundleExecutable = root.appendingPathComponent(
        "Applications/Codex.app/Contents/Resources/codex"
      )
      try makeExecutable(at: bundleExecutable)

      let candidates = CodexMacExecutableResolver.candidates(
        environment: ["HOME": root.path, "PATH": "/empty"]
      )

      XCTAssertTrue(candidates.contains(bundleExecutable.path))
      XCTAssertEqual(
        candidates.last,
        root.appendingPathComponent(
          "Library/Application Support/codex-plusplus/backup/Codex.app/Contents/Resources/codex"
        ).path
      )
    }

    func testResolvesNVMAndConfiguredNpmPrefixWithoutShellInitialization() throws {
      let root = try makeTemporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let nvmExecutable = root.appendingPathComponent(
        ".nvm/versions/node/v22.19.0/bin/codex"
      )
      try makeExecutable(at: nvmExecutable)

      let configuredExecutable = root.appendingPathComponent("npm-prefix/bin/codex")
      try makeExecutable(at: configuredExecutable)
      let environment = [
        "HOME": root.path,
        "PATH": "/empty",
        "NPM_CONFIG_PREFIX": configuredExecutable.deletingLastPathComponent()
          .deletingLastPathComponent().path,
      ]

      let candidates = CodexMacExecutableResolver.candidates(environment: environment)
      XCTAssertTrue(candidates.contains(configuredExecutable.path))
      XCTAssertTrue(
        CodexMacExecutableResolver.candidates(environment: [
          "HOME": root.path,
          "PATH": "/empty",
        ]).contains(nvmExecutable.path)
      )
    }

    func testExplicitExecutableHasHighestPrecedence() throws {
      let root = try makeTemporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let explicit = root.appendingPathComponent("explicit/codex")
      let bundle = root.appendingPathComponent(
        "Applications/Codex.app/Contents/Resources/codex"
      )
      try makeExecutable(at: explicit)
      try makeExecutable(at: bundle)

      let resolved = CodexMacExecutableResolver.resolve(
        environment: [
          "HOME": root.path,
          "PATH": "/empty",
          "CODEX_BRIDGE_CODEX_EXECUTABLE": explicit.path,
        ]
      )

      XCTAssertEqual(resolved?.path, explicit.path)
    }

    private func makeTemporaryRoot() throws -> URL {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-codex-mac-resolver-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      return root
    }

    private func makeExecutable(at url: URL) throws {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("#!/bin/sh\n".utf8).write(to: url)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)],
        ofItemAtPath: url.path
      )
    }
  }
#endif

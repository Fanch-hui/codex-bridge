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

    func testConfiguredPathMustBeAnExecutableFile() throws {
      let root = try makeTemporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let executable = root.appendingPathComponent("bin/codex")
      try makeExecutable(at: executable)
      let plain = root.appendingPathComponent("bin/notes.txt")
      try Data("codex".utf8).write(to: plain)

      XCTAssertEqual(
        CodexMacExecutableResolver.resolve(configuredPath: executable.path)?.path,
        executable.path
      )
      XCTAssertNil(
        CodexMacExecutableResolver.resolve(
          configuredPath: root.appendingPathComponent("bin").path
        )
      )
      XCTAssertNil(CodexMacExecutableResolver.resolve(configuredPath: plain.path))
      XCTAssertNil(CodexMacExecutableResolver.resolve(configuredPath: "codex"))
      XCTAssertNil(CodexMacExecutableResolver.resolve(configuredPath: ""))
    }

    func testConfiguredPathAcceptsQuotedClipboardForms() throws {
      let root = try makeTemporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let executable = root.appendingPathComponent("bin/codex")
      try makeExecutable(at: executable)

      XCTAssertEqual(
        CodexMacExecutableResolver.resolve(configuredPath: "\"\(executable.path)\"")?.path,
        executable.path
      )
      XCTAssertEqual(
        CodexMacExecutableResolver.resolve(configuredPath: "  '\(executable.path)'\n")?.path,
        executable.path
      )
      XCTAssertEqual(
        AppServerConfiguration.codex(configuredPath: "\"\(executable.path)\"").executableURL.path,
        executable.path
      )
      XCTAssertNil(CodexMacExecutableResolver.resolve(configuredPath: "\"\""))
    }

    func testConfiguredPathOverridesAutomaticDiscovery() throws {
      let root = try makeTemporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let executable = root.appendingPathComponent("custom/codex")
      try makeExecutable(at: executable)

      let configuration = AppServerConfiguration.codex(configuredPath: executable.path)
      XCTAssertEqual(configuration.executableURL.path, executable.path)
      XCTAssertEqual(configuration.arguments, ["app-server", "--stdio"])
      XCTAssertNil(configuration.launchFailureReason)
    }

    func testUnavailableConfiguredPathBlocksTheLaunch() {
      let configuration = AppServerConfiguration.codex(
        configuredPath: "/missing/codex-\(UUID().uuidString)"
      )
      XCTAssertNotNil(configuration.launchFailureReason)
      XCTAssertNotEqual(configuration.executableURL.path, "/usr/bin/env")
    }

    func testLocatorAppliesAndClearsConfiguredPath() throws {
      let root = try makeTemporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let executable = root.appendingPathComponent("custom/codex")
      try makeExecutable(at: executable)
      let automatic = AppServerConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/false"),
        arguments: []
      )
      let locator = CodexAppServerLocator(configuration: automatic)
      XCTAssertEqual(locator.current(), automatic)

      locator.update(configuredPath: "   ")
      XCTAssertEqual(locator.current(), automatic)

      locator.update(configuredPath: executable.path)
      XCTAssertEqual(locator.current().executableURL.path, executable.path)
      XCTAssertEqual(locator.current().arguments, ["app-server", "--stdio"])

      locator.update(configuredPath: nil)
      XCTAssertEqual(locator.current(), automatic)
    }

    func testLocatorBlocksAnUnavailableConfiguredPath() {
      let automatic = AppServerConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/false"),
        arguments: []
      )
      let locator = CodexAppServerLocator(configuration: automatic)
      locator.update(configuredPath: "/missing/codex-\(UUID().uuidString)")
      XCTAssertNotNil(locator.current().launchFailureReason)
    }

    func testLocatorReResolvesAutomaticDiscoveryOnEverySpawn() {
      let counter = LockedCounter()
      let locator = CodexAppServerLocator(resolve: {
        AppServerConfiguration(
          executableURL: URL(fileURLWithPath: "/bin/echo"),
          arguments: ["spawn-\(counter.next())"]
        )
      })

      XCTAssertEqual(locator.current().arguments, ["spawn-0"])
      XCTAssertEqual(locator.current().arguments, ["spawn-1"])

      locator.update(configuredPath: "/missing/codex-\(UUID().uuidString)")
      XCTAssertNotNil(locator.current().launchFailureReason)

      locator.update(configuredPath: nil)
      XCTAssertEqual(locator.current().arguments, ["spawn-2"])
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

  private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
      lock.lock()
      defer { lock.unlock() }
      let current = value
      value += 1
      return current
    }
  }
#endif

import BridgeCodexRPC
import BridgeServiceHost
import Foundation
import XCTest

final class CodexExecutableHostTests: XCTestCase {
  func testConfiguredCodexExecutableIsValidatedPersistedAndCleared() async throws {
    let fixture = try await makeServiceHostFixture(self)
    let composition = fixture.composition

    let initial = await composition.runtimeStatus.current()
    XCTAssertNil(initial.codexExecutablePath)

    do {
      try await composition.setCodexExecutablePath("/missing/codex-\(UUID().uuidString)")
      XCTFail("An unavailable Codex executable must be rejected.")
    } catch let error as ServiceCodexExecutableError {
      XCTAssertEqual(error, .unavailable)
    }
    let afterRejection = await composition.runtimeStatus.current()
    XCTAssertNil(afterRejection.codexExecutablePath)

    let executable = fixture.root.appending(path: "bin/codex")
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o700)],
      ofItemAtPath: executable.path
    )

    let applied = try await composition.setCodexExecutablePath(executable.path)
    XCTAssertEqual(applied.codexExecutablePath, executable.path)
    XCTAssertEqual(applied.codexResolvedExecutablePath, executable.path)
    let stored = try await composition.settings.codexExecutablePath()
    XCTAssertEqual(stored, executable.path)

    let cleared = try await composition.setCodexExecutablePath(nil)
    XCTAssertNil(cleared.codexExecutablePath)
    let storedAfterClear = try await composition.settings.codexExecutablePath()
    XCTAssertNil(storedAfterClear)
  }

  func testConfiguredCodexExecutableIsRestoredAfterRestart() async throws {
    let fixture = try await makeServiceHostFixture(self)
    let executable = fixture.root.appending(path: "bin/codex")
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o700)],
      ofItemAtPath: executable.path
    )
    _ = try await fixture.composition.setCodexExecutablePath(executable.path)

    let restarted = try await ServiceComposition.make(
      configuration: ServiceCompositionConfiguration(
        appVersion: "0.2.0",
        dataRootURL: fixture.root,
        clientInfo: .bridge(version: "codex-executable-tests")
      ),
      secretStore: ServiceHostTestSecretStore(),
      randomBytes: { count in Data((0..<count).map { UInt8(($0 + 17) % 255) }) }
    )
    addTeardownBlock { await restarted.shutdown() }

    let status = await restarted.runtimeStatus.current()
    XCTAssertEqual(status.codexExecutablePath, executable.path)
    XCTAssertEqual(status.codexResolvedExecutablePath, executable.path)
  }
}

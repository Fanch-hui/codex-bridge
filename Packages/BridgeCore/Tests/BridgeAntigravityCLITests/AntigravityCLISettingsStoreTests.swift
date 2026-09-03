import BridgeAgentCore
import Foundation
import XCTest

@testable import BridgeAntigravityCLI

final class AntigravityCLISettingsStoreTests: XCTestCase {
  func testMissingSettingsUsesDefaultsAndCreatesPrivateGlobalFile() async throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let store = AntigravityCLISettingsStore(sourceEnvironment: ["HOME": home])
    let installation = try makeInstallation()

    let initial = try await store.snapshot(installation: installation)

    XCTAssertEqual(initial.toolPermission, "request-review")
    XCTAssertNil(initial.revision)
    XCTAssertTrue(initial.rules.isEmpty)

    let saved = try await store.update(
      installation: installation,
      mutation: .addRule(effect: .allow, action: "read_url", target: "example.com"),
      expectedRevision: initial.revision
    )

    XCTAssertNotNil(saved.revision)
    XCTAssertEqual(saved.rules.map(\.target), ["example.com"])
    let path = settingsPath(home: home)
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
        as? [String: Any]
    )
    let permissions = try XCTUnwrap(json["permissions"] as? [String: Any])
    XCTAssertEqual(permissions["allow"] as? [String], ["read_url(example.com)"])
  }

  func testUpdatePreservesUnknownJSONAndReportsConflicts() async throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    try writeSettings(
      home: home,
      object: [
        "futureSetting": ["enabled": true],
        "permissions": [
          "allow": ["command(git status)"],
          "ask": ["command(git status)"],
          "futureEffect": ["future(value)"],
        ],
      ]
    )
    let store = AntigravityCLISettingsStore(sourceEnvironment: ["HOME": home])
    let installation = try makeInstallation()
    let initial = try await store.snapshot(installation: installation)

    XCTAssertTrue(initial.warnings.contains(where: { $0.contains("precedence") }))
    let saved = try await store.update(
      installation: installation,
      mutation: .setToolPermission("strict"),
      expectedRevision: initial.revision
    )

    XCTAssertEqual(saved.toolPermission, "strict")
    let json = try readSettings(home: home)
    XCTAssertEqual((json["futureSetting"] as? [String: Bool])?["enabled"], true)
    let permissions = try XCTUnwrap(json["permissions"] as? [String: Any])
    XCTAssertEqual(permissions["futureEffect"] as? [String], ["future(value)"])
  }

  func testOfficialModesAndActionsRoundTripThroughSparseMutations() async throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let store = AntigravityCLISettingsStore(sourceEnvironment: ["HOME": home])
    let installation = try makeInstallation()
    var snapshot = try await store.snapshot(installation: installation)

    for mode in ["request-review", "proceed-in-sandbox", "strict", "always-proceed"] {
      snapshot = try await store.update(
        installation: installation,
        mutation: .setToolPermission(mode),
        expectedRevision: snapshot.revision
      )
      XCTAssertEqual(snapshot.toolPermission, mode)
    }

    let rules = [
      ("command", "swift test"),
      ("read_url", "docs.example.com"),
      ("execute_url", "app.example.com"),
      ("mcp", "github/search"),
      ("read_file", "/tmp/project/readme.md"),
      ("write_file", "/tmp/project/output.txt"),
      ("unsandboxed", "developer-tool"),
    ]
    for (action, target) in rules {
      snapshot = try await store.update(
        installation: installation,
        mutation: .addRule(effect: .allow, action: action, target: target),
        expectedRevision: snapshot.revision
      )
    }

    XCTAssertEqual(Set(snapshot.rules.map(\.action)), Set(rules.map(\.0)))
    XCTAssertEqual(Set(snapshot.rules.map(\.target)), Set(rules.map(\.1)))
    XCTAssertTrue(snapshot.warnings.contains(where: { $0.contains("Always Proceed") }))
    XCTAssertTrue(snapshot.warnings.contains(where: { $0.contains("broad or unsandboxed") }))
  }

  func testSensitiveAndUnknownRulesAreRedactedAndRemovableByOpaqueID() async throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    try writeSettings(
      home: home,
      object: [
        "permissions": [
          "allow": [
            "read_url(https://user:password@example.com/private)",
            "future_action(value)",
          ]
        ]
      ]
    )
    let store = AntigravityCLISettingsStore(sourceEnvironment: ["HOME": home])
    let installation = try makeInstallation()
    let initial = try await store.snapshot(installation: installation)

    let sensitive = try XCTUnwrap(initial.rules.first(where: \.isRedacted))
    XCTAssertEqual(sensitive.target, "••••••")
    XCTAssertFalse(sensitive.isEditable)
    let unknown = try XCTUnwrap(initial.rules.first(where: { $0.action == "unknown" }))
    XCTAssertFalse(unknown.isEditable)

    let saved = try await store.update(
      installation: installation,
      mutation: .removeRule(id: sensitive.id),
      expectedRevision: initial.revision
    )

    XCTAssertEqual(saved.rules.count, 1)
    XCTAssertEqual(saved.rules.first?.id, unknown.id)
  }

  func testStaleRevisionCannotOverwriteExternalChange() async throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    try writeSettings(home: home, object: ["toolPermission": "strict"])
    let store = AntigravityCLISettingsStore(sourceEnvironment: ["HOME": home])
    let installation = try makeInstallation()
    let initial = try await store.snapshot(installation: installation)
    try writeSettings(home: home, object: ["toolPermission": "request-review"])

    await assertThrowsErrorAsync(
      try await store.update(
        installation: installation,
        mutation: .setToolPermission("always-proceed"),
        expectedRevision: initial.revision
      )
    ) { error in
      XCTAssertEqual(error as? AgentNativePermissionPolicyError, .revisionConflict)
    }
    XCTAssertEqual(try readSettings(home: home)["toolPermission"] as? String, "request-review")
  }

  func testInvalidJSONAndUnsafeRuleDoNotModifyFile() async throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let path = settingsPath(home: home)
    try FileManager.default.createDirectory(
      atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
      withIntermediateDirectories: true
    )
    let invalid = Data("{invalid".utf8)
    try invalid.write(to: URL(fileURLWithPath: path))
    let store = AntigravityCLISettingsStore(sourceEnvironment: ["HOME": home])

    await assertThrowsErrorAsync(try await store.snapshot(installation: makeInstallation())) {
      error in
      XCTAssertEqual(error as? AgentNativePermissionPolicyError, .settingsInvalid)
    }
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), invalid)

    try writeSettings(home: home, object: [:])
    let clean = try await store.snapshot(installation: makeInstallation())
    await assertThrowsErrorAsync(
      try await store.update(
        installation: makeInstallation(),
        mutation: .addRule(
          effect: .allow,
          action: "command",
          target: "curl -H Authorization:Bearer-token example.com"
        ),
        expectedRevision: clean.revision
      )
    ) { error in
      XCTAssertEqual(error as? AgentNativePermissionPolicyError, .ruleInvalid)
    }
    XCTAssertEqual(try readSettings(home: home).count, 0)
  }

  func testProviderExposesSharedPermissionManager() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let provider = try AntigravityCLIProvider(
      configuration: .init(sourceEnvironment: ["HOME": home])
    )

    XCTAssertNotNil(provider.nativePermissionPolicyManager)
  }

  func testConcurrentUpdatesWithOneRevisionDoNotLoseChanges() async throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let store = AntigravityCLISettingsStore(sourceEnvironment: ["HOME": home])
    let installation = try makeInstallation()
    let first = Task {
      try await store.update(
        installation: installation,
        mutation: .addRule(effect: .allow, action: "read_url", target: "one.example"),
        expectedRevision: nil
      )
    }
    let second = Task {
      try await store.update(
        installation: installation,
        mutation: .addRule(effect: .allow, action: "read_url", target: "two.example"),
        expectedRevision: nil
      )
    }

    let results = [try? await first.value, try? await second.value]
    let snapshot = try await store.snapshot(installation: installation)

    XCTAssertEqual(results.compactMap { $0 }.count, 1)
    XCTAssertEqual(snapshot.rules.count, 1)
  }

  func testSymbolicLinkSettingsFileIsRejected() async throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let path = settingsPath(home: home)
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    let target = URL(fileURLWithPath: home).appendingPathComponent("unrelated.json").path
    try Data("{\"toolPermission\":\"strict\"}".utf8).write(
      to: URL(fileURLWithPath: target)
    )
    try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
    let store = AntigravityCLISettingsStore(sourceEnvironment: ["HOME": home])

    await assertThrowsErrorAsync(try await store.snapshot(installation: makeInstallation())) {
      error in
      XCTAssertEqual(error as? AgentNativePermissionPolicyError, .settingsUnsafe)
    }
  }

  func testSameBytesReplacementDuringMutationIsRejected() async throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    try writeSettings(home: home, object: ["toolPermission": "strict"])
    let file = try AntigravityCLISettingsFile(sourceEnvironment: ["HOME": home])
    let original = try XCTUnwrap(file.read())
    try writeSettings(home: home, object: ["toolPermission": "strict"])

    XCTAssertThrowsError(
      try file.write(
        Data("{\"toolPermission\":\"request-review\"}\n".utf8),
        expectedRevision: AntigravityCLISettingsDocument.digest(original.data),
        expectedIdentity: original.identity
      )
    ) { error in
      XCTAssertEqual(error as? AgentNativePermissionPolicyError, .revisionConflict)
    }
    XCTAssertEqual(try readSettings(home: home)["toolPermission"] as? String, "strict")
  }

  private func makeInstallation() throws -> AgentInstallation {
    try AgentInstallation(
      id: AgentInstallationID(rawValue: "agy-settings"),
      providerID: .antigravity,
      executablePath: "/bin/echo"
    )
  }

  private func temporaryHome() throws -> String {
    try AntigravityCLITestSupport.temporaryDirectory(prefix: "agy-settings-home")
  }

  private func settingsPath(home: String) -> String {
    URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent(".gemini/antigravity-cli/settings.json").path
  }

  private func writeSettings(home: String, object: [String: Any]) throws {
    let path = settingsPath(home: home)
    try FileManager.default.createDirectory(
      atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
  }

  private func readSettings(home: String) throws -> [String: Any] {
    try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: URL(fileURLWithPath: settingsPath(home: home)))
      ) as? [String: Any]
    )
  }
}

private func assertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  _ errorHandler: (any Error) -> Void = { _ in },
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected expression to throw", file: file, line: line)
  } catch {
    errorHandler(error)
  }
}

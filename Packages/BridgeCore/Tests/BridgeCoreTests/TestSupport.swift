import BridgeDomain
import BridgeProjects
import BridgeServiceCore
import Foundation
import Testing

/// Shared fixtures for the pure-logic test suite. Every helper is platform
/// neutral: the project roots differ per operating system because
/// `ServiceRootIdentity` validates with the current path style.
enum TestFixtures {

  /// An absolute, non-existent project root accepted by
  /// `ServiceRootIdentity` on the platform running the suite.
  static var projectRootPath: String {
    #if os(Windows)
      return "C:\\codex-bridge-tests\\proj"
    #else
      return "/codex-bridge-tests/proj"
    #endif
  }

  static func makeProjectRecord(
    mode: ServiceDirectCommandMode,
    commands: [ServiceWorkspaceCommand] = [],
    blacklist: [ServiceCommandBlacklistRule] = [],
    accessPolicy: ProjectAccessPolicy = ProjectAccessPolicy(
      read: .allowed, write: .allowed, network: .denied)
  ) throws -> ServiceProjectRecord {
    let identity = try ServiceRootIdentity(
      canonicalPath: projectRootPath,
      device: 17,
      inode: 42
    )
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    return try ServiceProjectRecord(
      id: ProjectID(rawValue: "proj-1"),
      name: "Test Project",
      root: identity,
      accessPolicy: accessPolicy,
      directCommandMode: mode,
      workspaceCommands: commands,
      commandBlacklist: blacklist,
      createdAt: now,
      updatedAt: now
    )
  }

  static func makeCommand(
    id: String,
    executable: String,
    arguments: [String] = [],
    requiresNetwork: Bool = false,
    risk: ServiceWorkspaceCommandRisk = .normal
  ) throws -> ServiceWorkspaceCommand {
    try ServiceWorkspaceCommand(
      id: id,
      name: id,
      executable: executable,
      arguments: arguments,
      workingDirectory: nil,
      requiresNetwork: requiresNetwork,
      risk: risk
    )
  }

  static func makeBlacklistRule(
    id: String,
    executable: String? = nil,
    pattern: String? = nil,
    arguments: [String]? = nil
  ) throws -> ServiceCommandBlacklistRule {
    try ServiceCommandBlacklistRule(
      id: id,
      executable: executable,
      pattern: pattern,
      arguments: arguments
    )
  }

  /// Builds NUL-terminated `git status --porcelain=v2 -z` records the same way
  /// Git emits them: each record is terminated by a single 0x00 byte.
  static func porcelain(_ records: [String]) -> Data {
    Data(records.flatMap { Array($0.utf8) + [0] })
  }
}

/// Runs `body`, captures a thrown error, and asserts it equals `expected`.
/// Used instead of `#expect(throws:)` so the suite only depends on the most
/// stable subset of the swift-testing API.
func expectError<E: Error & Equatable>(
  _ expected: E,
  sourceLocation: SourceLocation = #_sourceLocation,
  _ body: () throws -> Void
) {
  var thrown: E?
  do {
    try body()
  } catch let error as E {
    thrown = error
  } catch {
    // A different error type is still a failure below.
  }
  #expect(thrown == expected, sourceLocation: sourceLocation)
}

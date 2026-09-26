import BridgeAgentCore
import Foundation
import Testing

@testable import BridgePiRPC

struct PiNativePermissionPolicyManagerTests {
  @Test func persistsBridgeRulesAndRejectsStaleRevision() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pi-native-permissions-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let installation = try AgentInstallation(
      id: AgentInstallationID(rawValue: "pi-test"),
      providerID: .pi,
      executablePath: directory.appendingPathComponent("pi").path
    )
    let manager = PiNativePermissionPolicyManager(runtimeBaseDirectory: directory.path)
    let initial = try await manager.snapshot(installation: installation)
    let updated = try await manager.update(
      installation: installation,
      mutation: .addRule(effect: .allow, action: "write", target: "src/**"),
      expectedRevision: initial.revision
    )

    #expect(updated.rules.map(\.target) == ["src/**"])
    #expect(updated.warnings.contains(where: { $0.contains("只读上限") }))
    await #expect(throws: AgentNativePermissionPolicyError.revisionConflict) {
      try await manager.update(
        installation: installation,
        mutation: .removeRule(id: updated.rules[0].id),
        expectedRevision: initial.revision
      )
    }
    let reloaded = try await manager.snapshot(installation: installation)
    #expect(reloaded.rules == updated.rules)
  }
}

import BridgeAgentCore
import Foundation
import Testing

@testable import BridgeQoderSDK

struct QoderNativePermissionPolicyManagerTests {
  @Test func editsOfficialRegionSettingsWithoutReplacingOtherConfiguration() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("qoder-native-permissions-\(UUID().uuidString)", isDirectory: true)
    let settingsDirectory = temporary.appendingPathComponent("cn", isDirectory: true)
    try FileManager.default.createDirectory(
      at: settingsDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let settingsURL = settingsDirectory.appendingPathComponent("settings.json")
    try Data(
      #"{"language":"Chinese","general":{"preferredEditor":"vim"},"permissions":{"allow":["Read"]}}"#
        .utf8
    ).write(to: settingsURL)

    let executable = temporary.appendingPathComponent("qodercn").path
    let installation = try AgentInstallation(
      id: AgentInstallationID(rawValue: "qoder-cn-test"),
      providerID: .qoder,
      executablePath: executable
    )
    let manager = QoderNativePermissionPolicyManager(
      sourceEnvironment: ["QODERCN_CONFIG_DIR": settingsDirectory.path]
    )
    let initial = try await manager.snapshot(installation: installation)
    let updated = try await manager.update(
      installation: installation,
      mutation: .addRule(effect: .deny, action: "Bash", target: "rm -rf:*"),
      expectedRevision: initial.revision
    )

    #expect(updated.rules.contains(where: { $0.action == "Bash" && $0.target == "rm -rf:*" }))
    await #expect(throws: AgentNativePermissionPolicyError.revisionConflict) {
      try await manager.update(
        installation: installation,
        mutation: .removeRule(id: updated.rules[0].id),
        expectedRevision: initial.revision
      )
    }
    let saved =
      try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
    #expect(saved?["language"] as? String == "Chinese")
    #expect((saved?["general"] as? [String: Any])?["preferredEditor"] as? String == "vim")
    let permissions = saved?["permissions"] as? [String: Any]
    #expect((permissions?["allow"] as? [String]) == ["Read"])
    #expect((permissions?["deny"] as? [String]) == ["Bash(rm -rf:*)"])
  }
}

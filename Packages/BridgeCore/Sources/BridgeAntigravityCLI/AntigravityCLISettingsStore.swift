import BridgeAgentCore
import Foundation

public actor AntigravityCLISettingsStore: AgentNativePermissionPolicyManaging {
  private let settingsFile: AntigravityCLISettingsFile?

  public init(sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
    settingsFile = try? AntigravityCLISettingsFile(sourceEnvironment: sourceEnvironment)
  }

  public func snapshot(
    installation: AgentInstallation
  ) async throws -> AgentNativePermissionPolicySnapshot {
    try validate(installation)
    let settingsFile = try availableSettingsFile()
    let document = try AntigravityCLISettingsDocument(data: settingsFile.read()?.data)
    return try document.snapshot(
      providerID: .antigravity,
      installationID: installation.id
    )
  }

  public func update(
    installation: AgentInstallation,
    mutation: AgentNativePermissionMutation,
    expectedRevision: String?
  ) async throws -> AgentNativePermissionPolicySnapshot {
    try validate(installation)
    let settingsFile = try availableSettingsFile()
    let original = try settingsFile.read()
    var document = try AntigravityCLISettingsDocument(data: original?.data)
    guard document.revision == expectedRevision else {
      throw AgentNativePermissionPolicyError.revisionConflict
    }
    try document.apply(mutation)
    try settingsFile.write(
      document.encoded(),
      expectedRevision: expectedRevision,
      expectedIdentity: original?.identity
    )
    let saved = try AntigravityCLISettingsDocument(data: settingsFile.read()?.data)
    return try saved.snapshot(providerID: .antigravity, installationID: installation.id)
  }

  public func remediation(
    toolName: String,
    toolArguments: String
  ) async -> AgentNativePermissionRemediation? {
    AntigravityCLIPermissionRemediation.make(
      toolName: toolName,
      toolArguments: toolArguments
    )
  }

  private func validate(_ installation: AgentInstallation) throws {
    guard installation.providerID == .antigravity else {
      throw AgentNativePermissionPolicyError.unavailable
    }
    _ = try AntigravityCLILaunchRuntime.resolveExecutable(installation.executablePath)
  }

  private func availableSettingsFile() throws -> AntigravityCLISettingsFile {
    guard let settingsFile else { throw AgentNativePermissionPolicyError.unavailable }
    return settingsFile
  }
}

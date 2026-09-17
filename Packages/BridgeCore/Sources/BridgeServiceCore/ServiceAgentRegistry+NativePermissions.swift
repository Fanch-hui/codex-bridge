import BridgeAgentCore

extension ServiceAgentRegistry {
  public func nativePermissionPolicy(
    installationID: AgentInstallationID
  ) async throws -> AgentNativePermissionPolicySnapshot {
    let (manager, installation) = try await nativePermissionContext(
      installationID: installationID
    )
    return try await manager.snapshot(installation: installation)
  }

  public func updateNativePermissionPolicy(
    installationID: AgentInstallationID,
    mutation: AgentNativePermissionMutation,
    expectedRevision: String?
  ) async throws -> AgentNativePermissionPolicySnapshot {
    let (manager, installation) = try await nativePermissionContext(
      installationID: installationID
    )
    return try await manager.update(
      installation: installation,
      mutation: mutation,
      expectedRevision: expectedRevision
    )
  }

  public func nativePermissionRemediation(
    installationID: AgentInstallationID,
    toolName: String,
    toolArguments: String
  ) async throws -> AgentNativePermissionRemediation? {
    let (manager, _) = try await nativePermissionContext(
      installationID: installationID
    )
    return await manager.remediation(
      toolName: toolName,
      toolArguments: toolArguments
    )
  }

  private func nativePermissionContext(
    installationID: AgentInstallationID
  ) async throws -> (any AgentNativePermissionPolicyManaging, AgentInstallation) {
    let record = try await validateForExecution(installationID: installationID)
    let provider = try provider(for: record.providerID)
    guard let manager = provider.nativePermissionPolicyManager else {
      throw AgentNativePermissionPolicyError.unavailable
    }
    return (manager, try record.agentInstallation())
  }
}

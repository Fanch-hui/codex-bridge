import BridgeAgentCore

extension ServiceAgentRegistry {
  public func nativeSessionDirectoryManager(
    installationID: AgentInstallationID
  ) async throws -> (
    any AgentNativeSessionDirectoryManaging,
    AgentInstallation,
    ServiceAgentInstallationRecord
  ) {
    let record = try await validateForExecution(installationID: installationID)
    let provider = try provider(for: record.providerID)
    guard let source = provider as? any AgentNativeSessionDirectoryProviding,
      let manager = source.nativeSessionDirectoryManager
    else { throw AgentNativeSessionDirectoryError.unavailable }
    return (manager, try record.agentInstallation(), record)
  }
}

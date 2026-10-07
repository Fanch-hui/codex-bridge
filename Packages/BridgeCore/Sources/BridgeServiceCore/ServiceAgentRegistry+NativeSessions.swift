import BridgeAgentCore

extension ServiceAgentRegistry {
  public func nativeSessionDirectoryManager(
    installationID: AgentInstallationID
  ) async throws -> (
    any AgentNativeSessionDirectoryManaging,
    AgentInstallation,
    ServiceAgentInstallationRecord
  ) {
    let record: ServiceAgentInstallationRecord
    if let stored = try await store.agentInstallation(id: installationID),
      stored.providerID == .deepSeekHarness || stored.providerID == .deepSeekHarnessDesktop
    {
      let binding = try await selectedRuntimeBinding(for: stored)
      guard binding?.connectionMode == .nativeDesktop else {
        throw AgentNativeSessionDirectoryError.unsupported
      }
      record = try await validateForRuntimeBinding(
        installationID: installationID,
        runtimeBinding: binding)
    } else {
      record = try await validateForExecution(installationID: installationID)
    }
    let provider = try provider(for: record.providerID)
    guard let source = provider as? any AgentNativeSessionDirectoryProviding else {
      throw AgentNativeSessionDirectoryError.unsupported
    }
    guard let manager = source.nativeSessionDirectoryManager else {
      throw AgentNativeSessionDirectoryError.unavailable
    }
    return (manager, try record.agentInstallation(), record)
  }
}

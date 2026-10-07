import BridgeAgentCore

extension BridgeServiceApplication {
  func withDeepSeekDesktopSelection<Result: Sendable>(
    mode: DeepSeekHarnessConnectionMode, installationID: String? = nil,
    operation: @Sendable () async throws -> Result
  ) async throws -> Result {
    let previous = try await settings.deepSeekHarnessConnectionSelection()
    do {
      try await settings.setDeepSeekHarnessConnectionSelection(
        mode: mode.rawValue,
        activeInstallationID: installationID ?? previous.activeInstallationID)
      return try await operation()
    } catch {
      try? await settings.setDeepSeekHarnessConnectionSelection(
        mode: previous.mode, activeInstallationID: previous.activeInstallationID)
      throw error
    }
  }
}

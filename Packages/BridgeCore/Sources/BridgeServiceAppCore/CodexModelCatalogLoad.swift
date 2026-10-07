import BridgeIPC

@MainActor
public enum CodexModelCatalogLoad {
  public static func load(
    client: any BridgeServiceClientProtocol,
    forceRefresh: Bool,
    recoverInitialFailure: Bool,
    isCurrent: () -> Bool,
    recoveryDelay: Duration = .seconds(1)
  ) async throws -> IPCModelCatalogResponse {
    do {
      return try await client.modelCatalog(forceRefresh: forceRefresh)
    } catch BridgeServiceIPCCodecError.remoteError(let failure)
      where recoverInitialFailure && !forceRefresh && isCurrent()
      && failure.code == "codex_app_server_unavailable" && failure.retryable
    {
      // Startup failures otherwise remain visible until a manual model refresh.
      try await Task.sleep(for: recoveryDelay)
      try Task.checkCancellation()
      guard isCurrent() else { throw CancellationError() }
      return try await client.modelCatalog(forceRefresh: true)
    }
  }
}

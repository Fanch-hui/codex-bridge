extension BridgeServiceClient {
  public func beginAgentSetup(_ request: IPCAgentSetupRequest) async throws -> IPCAgentSetupState {
    try await call(operation: .beginAgentSetup, payload: request)
  }

  public func agentSetups() async throws -> [IPCAgentSetupState] {
    try await call(operation: .getAgentSetups, payload: Optional<IPCAgentSetupIDRequest>.none)
  }

  public func continueAgentSetup(_ request: IPCAgentSetupContinueRequest) async throws
    -> IPCAgentSetupState
  {
    try await call(operation: .continueAgentSetup, payload: request)
  }

  public func cancelAgentSetup(operationID: String) async throws -> IPCAgentSetupState {
    try await call(
      operation: .cancelAgentSetup, payload: IPCAgentSetupIDRequest(operationID: operationID))
  }
}

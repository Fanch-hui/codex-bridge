import BridgeAgentCore

extension AgentModelCatalogError {
  var modelCatalogToolError: MCPToolErrorDTO {
    MCPToolErrorDTO(
      code: code,
      category: requiresConnectionConfiguration ? .capabilityUnavailable : .infrastructureFailure,
      message: errorDescription ?? "The Agent model catalog is unavailable.",
      retryable: retryable,
      nextAction: nextAction)
  }
}

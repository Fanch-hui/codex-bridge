import BridgeIPC
import BridgeServiceApplication
import BridgeServiceCore
import Foundation

extension BridgeServiceRequestController {
  func handleListDeepSeekHarnessMCPServers(
    _ request: BridgeServiceIPCRequest
  ) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.optionalPayload(
      IPCAgentMCPListRequest.self, from: request)
    let configuration = try await agentMCPConfiguration(scope: payload?.scope)
    let servers = try await configuration.list()
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCDeepSeekHarnessMCPListResponse(servers: servers.map(Self.mcpSummary))
    )
  }

  func handleSaveDeepSeekHarnessMCPServer(
    _ request: BridgeServiceIPCRequest
  ) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCDeepSeekHarnessMCPServerInput.self,
      from: request
    )
    guard let transport = ServiceDeepSeekHarnessMCPTransport(rawValue: payload.transport) else {
      throw ServiceStoreError.invalidArgument("dsh.mcp.transport")
    }
    let configuration = try await agentMCPConfiguration(scope: payload.scope)
    let saved = try await configuration.save(
      ServiceDeepSeekHarnessMCPServerInput(
        id: payload.id,
        name: payload.name,
        enabled: payload.enabled,
        transport: transport,
        command: payload.command,
        args: payload.args,
        url: payload.url,
        environment: payload.environment.map {
          ServiceDeepSeekHarnessMCPSecretInput(name: $0.name, value: $0.value)
        },
        headers: payload.headers.map {
          ServiceDeepSeekHarnessMCPSecretInput(name: $0.name, value: $0.value)
        }
      )
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: Self.mcpSummary(saved)
    )
  }

  func handleDeleteDeepSeekHarnessMCPServer(
    _ request: BridgeServiceIPCRequest
  ) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCDeepSeekHarnessMCPDeleteRequest.self,
      from: request
    )
    let configuration = try await agentMCPConfiguration(scope: payload.scope)
    try await configuration.delete(id: payload.id)
    return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
  }

  private func agentMCPConfiguration(scope: String?) async throws
    -> ServiceDeepSeekHarnessMCPConfiguration
  {
    guard let key = ServiceAgentMCPScope(rawValue: scope ?? "deepseek-harness"),
      let configuration = composition.agentMCP[key]
    else { throw ServiceStoreError.invalidArgument("agent.mcp.scope") }
    return configuration
  }

  private static func mcpSummary(
    _ summary: ServiceDeepSeekHarnessMCPServerSummary
  ) -> IPCDeepSeekHarnessMCPServerSummary {
    IPCDeepSeekHarnessMCPServerSummary(
      id: summary.id,
      name: summary.name,
      enabled: summary.enabled,
      transport: summary.transport.rawValue,
      command: summary.command,
      args: summary.args,
      url: summary.url,
      environment: summary.environment.map {
        IPCDeepSeekHarnessMCPSecretSummary(name: $0.name, hasValue: $0.hasValue)
      },
      headers: summary.headers.map {
        IPCDeepSeekHarnessMCPSecretSummary(name: $0.name, hasValue: $0.hasValue)
      }
    )
  }
}

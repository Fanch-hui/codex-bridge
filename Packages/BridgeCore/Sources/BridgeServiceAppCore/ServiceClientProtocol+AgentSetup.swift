import BridgeIPC
import Foundation

extension BridgeServiceClientProtocol {
  public func beginAgentSetup(_ request: IPCAgentSetupRequest) async throws -> IPCAgentSetupState {
    throw AgentSetupClientError.unsupported
  }

  public func agentSetups() async throws -> [IPCAgentSetupState] { [] }

  public func continueAgentSetup(_ request: IPCAgentSetupContinueRequest) async throws
    -> IPCAgentSetupState
  {
    throw AgentSetupClientError.unsupported
  }

  public func cancelAgentSetup(operationID: String) async throws -> IPCAgentSetupState {
    throw AgentSetupClientError.unsupported
  }
}

private enum AgentSetupClientError: LocalizedError {
  case unsupported

  var errorDescription: String? { "当前服务不支持一键配置，请更新 Codex Bridge。" }
}

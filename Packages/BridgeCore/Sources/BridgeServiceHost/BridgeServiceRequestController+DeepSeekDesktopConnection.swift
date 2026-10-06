import BridgeAgentCore
import BridgeDeepSeekHarnessACP
import BridgeIPC
import BridgeMCP
import BridgeServiceApplication
import BridgeServiceCore
import Foundation

extension BridgeServiceRequestController {
  func connectNativeDeepSeekDesktop(
    request: BridgeServiceIPCRequest,
    payload: IPCAgentConnectRequest
  ) async throws -> Data {
    let existing = try await composition.agentRegistry.installations(providerID: .deepSeekHarness)
    let candidates =
      existing.map(\.executablePath)
      + ServiceAgentAutoDiscovery.deepSeekDesktopCandidates(
        environment: ToolDiscoveryEnvironment.current())
    guard
      let path = candidates.first(where: { DeepSeekHarnessACPRuntimeLayout.desktop(at: $0) != nil })
    else { throw ServiceAgentConnectionError.installationNotFound }
    let candidate = try ServiceAgentRegistrationRequest(
      providerID: .deepSeekHarness,
      displayName: "DeepSeek Harness", executablePath: path, trustProfile: .userTrusted,
      enableOnSuccess: false,
      artifacts: [ServiceAgentInstallationArtifactRequest(role: .nodeInterpreter, path: path)])
    let record = try await composition.application.serviceConnectDeepSeekDesktop(
      candidate,
      deadline: Self.deadline())
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: Self.agentInstallationSummary(
        record, nativeSessionOperations: [], canOpenNativeSession: false))
  }
}

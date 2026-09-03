import BridgeAgentCore
import BridgeDomain
import BridgeIPC
import BridgeServiceApplication
import Foundation

extension BridgeServiceXPCController {
  func handleGetAgentNativePermissionPolicy(
    _ request: BridgeServiceIPCRequest
  ) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCAgentNativePermissionPolicyRequest.self,
      from: request
    )
    let snapshot = try await composition.application.serviceAgentNativePermissionPolicy(
      installationID: AgentInstallationID(rawValue: payload.installationID),
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: Self.nativePermissionPolicyResponse(snapshot)
    )
  }

  func handleUpdateAgentNativePermissionPolicy(
    _ request: BridgeServiceIPCRequest
  ) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCAgentNativePermissionMutationRequest.self,
      from: request
    )
    let snapshot = try await composition.application.serviceUpdateAgentNativePermissionPolicy(
      installationID: AgentInstallationID(rawValue: payload.installationID),
      mutation: try Self.nativePermissionMutation(payload),
      expectedRevision: payload.expectedRevision,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: Self.nativePermissionPolicyResponse(snapshot)
    )
  }

  func handleGetAgentPermissionRemediation(
    _ request: BridgeServiceIPCRequest
  ) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCAgentPermissionRemediationRequest.self,
      from: request
    )
    let remediation = try await composition.application.serviceAgentPermissionRemediation(
      taskID: TaskID(rawValue: payload.taskID),
      messageKey: payload.messageKey,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: Self.permissionRemediationResponse(remediation)
    )
  }

  func handleApplyAgentPermissionRemediation(
    _ request: BridgeServiceIPCRequest
  ) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCAgentPermissionRemediationApplyRequest.self,
      from: request
    )
    let snapshot = try await composition.application.serviceApplyAgentPermissionRemediation(
      taskID: TaskID(rawValue: payload.taskID),
      messageKey: payload.messageKey,
      candidateID: payload.candidateID,
      expectedRevision: payload.expectedRevision,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: Self.nativePermissionPolicyResponse(snapshot)
    )
  }

  private static func nativePermissionMutation(
    _ request: IPCAgentNativePermissionMutationRequest
  ) throws -> AgentNativePermissionMutation {
    switch request.operation {
    case .setToolPermission:
      guard let toolPermission = request.toolPermission,
        request.ruleID == nil,
        request.effect == nil,
        request.action == nil,
        request.target == nil
      else { throw BridgeServiceIPCCodecError.invalidMessage }
      return .setToolPermission(toolPermission)
    case .addRule:
      guard request.toolPermission == nil,
        request.ruleID == nil,
        let effect = nativePermissionEffect(request.effect),
        let action = request.action,
        let target = request.target
      else { throw BridgeServiceIPCCodecError.invalidMessage }
      return .addRule(effect: effect, action: action, target: target)
    case .replaceRule:
      guard request.toolPermission == nil,
        let ruleID = request.ruleID,
        let effect = nativePermissionEffect(request.effect),
        let action = request.action,
        let target = request.target
      else { throw BridgeServiceIPCCodecError.invalidMessage }
      return .replaceRule(id: ruleID, effect: effect, action: action, target: target)
    case .removeRule:
      guard request.toolPermission == nil,
        let ruleID = request.ruleID,
        request.effect == nil,
        request.action == nil,
        request.target == nil
      else { throw BridgeServiceIPCCodecError.invalidMessage }
      return .removeRule(id: ruleID)
    }
  }

  private static func nativePermissionEffect(
    _ rawValue: String?
  ) -> AgentNativePermissionEffect? {
    rawValue.flatMap(AgentNativePermissionEffect.init(rawValue:))
  }

  private static func nativePermissionPolicyResponse(
    _ snapshot: AgentNativePermissionPolicySnapshot
  ) -> IPCAgentNativePermissionPolicyResponse {
    IPCAgentNativePermissionPolicyResponse(
      providerID: snapshot.providerID.rawValue,
      installationID: snapshot.installationID.rawValue,
      toolPermission: snapshot.toolPermission,
      availableModes: snapshot.availableModes.map {
        IPCAgentNativePermissionModeSummary(
          modeID: $0.id,
          displayName: $0.displayName,
          requiresConfirmation: $0.requiresConfirmation
        )
      },
      availableActions: snapshot.availableActions,
      rules: snapshot.rules.map {
        IPCAgentNativePermissionRuleSummary(
          ruleID: $0.id,
          effect: $0.effect.rawValue,
          action: $0.action,
          target: $0.target,
          isEditable: $0.isEditable,
          isRedacted: $0.isRedacted,
          requiresConfirmation: $0.requiresConfirmation
        )
      },
      revision: snapshot.revision,
      warnings: snapshot.warnings
    )
  }

  private static func permissionRemediationResponse(
    _ remediation: ServiceAgentPermissionRemediation
  ) -> IPCAgentPermissionRemediationResponse {
    IPCAgentPermissionRemediationResponse(
      taskID: remediation.taskID.rawValue,
      messageKey: remediation.messageKey,
      installationID: remediation.installationID.rawValue,
      candidateID: remediation.candidate.candidateID,
      action: remediation.candidate.action,
      target: remediation.candidate.target,
      displayRule: remediation.candidate.displayRule,
      requiresConfirmation: remediation.candidate.requiresConfirmation,
      settingsRevision: remediation.settingsRevision
    )
  }
}

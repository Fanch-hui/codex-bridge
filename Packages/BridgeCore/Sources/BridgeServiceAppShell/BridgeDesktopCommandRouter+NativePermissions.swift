import BridgeDesktopUI
import BridgeIPC
import Foundation

extension BridgeDesktopCommandRouter {
  static func handleNativePermissions(
    _ envelope: BridgeDesktopCommandEnvelope,
    model: BridgeServiceAppModel
  ) {
    let payload = envelope.payload
    switch envelope.command {
    case .refreshAgentNativePermission:
      guard connected(model),
        let installationID = nativePermissionInstallationID(payload.installationID, model: model)
      else { return }
      model.focusedAgentNativePermissionInstallationID = installationID
      Task { await model.loadNativePermissionPolicy(installationID: installationID) }
    case .setAgentNativePermissionMode:
      setNativePermissionMode(payload, model: model)
    case .addAgentNativePermissionRule:
      mutateNativePermissionRule(payload, operation: .addRule, model: model)
    case .replaceAgentNativePermissionRule:
      mutateNativePermissionRule(payload, operation: .replaceRule, model: model)
    case .removeAgentNativePermissionRule:
      removeNativePermissionRule(payload, model: model)
    case .prepareAgentPermissionRemediation:
      preparePermissionRemediation(payload, model: model)
    case .applyAgentPermissionRemediation:
      applyPermissionRemediation(payload, model: model)
    default:
      return
    }
  }

  static func loadNativePermissionPolicyIfNeeded(_ model: BridgeServiceAppModel) {
    guard connected(model),
      let installationID = nativePermissionInstallationID(nil, model: model),
      model.nativePermissionPolicy(installationID: installationID) == nil,
      !model.isLoadingNativePermissionPolicy(installationID)
    else { return }
    Task { await model.loadNativePermissionPolicy(installationID: installationID) }
  }

  private static func setNativePermissionMode(
    _ payload: BridgeDesktopCommandPayload,
    model: BridgeServiceAppModel
  ) {
    guard let (installationID, snapshot) = nativePermissionContext(payload, model: model),
      let mode = validatedID(payload.toolPermission, maximumBytes: 128),
      let option = snapshot.availableModes.first(where: { $0.modeID == mode }),
      !option.requiresConfirmation || payload.confirmed == true
    else { return }
    model.updateNativePermissionPolicy(
      IPCAgentNativePermissionMutationRequest(
        installationID: installationID,
        expectedRevision: snapshot.revision,
        operation: .setToolPermission,
        toolPermission: mode
      )
    )
  }

  private static func mutateNativePermissionRule(
    _ payload: BridgeDesktopCommandPayload,
    operation: IPCAgentNativePermissionMutationOperation,
    model: BridgeServiceAppModel
  ) {
    guard let (installationID, snapshot) = nativePermissionContext(payload, model: model),
      let effect = validatedID(payload.effect, maximumBytes: 16),
      ["allow", "ask", "deny"].contains(effect),
      let action = validatedID(payload.action, maximumBytes: 128),
      snapshot.availableActions.contains(action),
      let target = nativePermissionTarget(payload.target)
    else { return }
    let ruleID: String?
    if operation == .replaceRule {
      guard let candidate = validatedID(payload.ruleID, maximumBytes: 128),
        let rule = snapshot.rules.first(where: { $0.ruleID == candidate }),
        rule.isEditable,
        (!rule.requiresConfirmation
          && !requiresRuleConfirmation(
            providerID: snapshot.providerID,
            effect: effect,
            action: action,
            target: target
          ))
          || payload.confirmed == true
      else { return }
      ruleID = candidate
    } else {
      guard operation == .addRule,
        !requiresRuleConfirmation(
          providerID: snapshot.providerID,
          effect: effect,
          action: action,
          target: target
        ) || payload.confirmed == true
      else { return }
      ruleID = nil
    }
    model.updateNativePermissionPolicy(
      IPCAgentNativePermissionMutationRequest(
        installationID: installationID,
        expectedRevision: snapshot.revision,
        operation: operation,
        ruleID: ruleID,
        effect: effect,
        action: action,
        target: target
      )
    )
  }

  private static func removeNativePermissionRule(
    _ payload: BridgeDesktopCommandPayload,
    model: BridgeServiceAppModel
  ) {
    guard let (installationID, snapshot) = nativePermissionContext(payload, model: model),
      let ruleID = validatedID(payload.ruleID, maximumBytes: 128),
      snapshot.rules.contains(where: { $0.ruleID == ruleID && $0.isEditable })
    else { return }
    model.updateNativePermissionPolicy(
      IPCAgentNativePermissionMutationRequest(
        installationID: installationID,
        expectedRevision: snapshot.revision,
        operation: .removeRule,
        ruleID: ruleID
      )
    )
  }

  private static func preparePermissionRemediation(
    _ payload: BridgeDesktopCommandPayload,
    model: BridgeServiceAppModel
  ) {
    guard connected(model),
      let taskID = validatedID(payload.taskID),
      let messageKey = validatedID(payload.messageKey),
      let task = model.tasks.first(where: {
        $0.taskID == taskID && $0.providerID == "antigravity"
          && $0.failureCode == "antigravity_permission_denied"
      }),
      model.selectedTaskID == nil || model.selectedTaskID == task.taskID,
      model.conversation?.entries.contains(where: {
        $0.key == messageKey && $0.kind == "tool_call" && $0.toolStatus == "declined"
      }) == true
    else { return }
    model.prepareDesktopPermissionRemediation(taskID: taskID, messageKey: messageKey)
  }

  private static func applyPermissionRemediation(
    _ payload: BridgeDesktopCommandPayload,
    model: BridgeServiceAppModel
  ) {
    guard connected(model), payload.confirmed == true,
      let taskID = validatedID(payload.taskID),
      let messageKey = validatedID(payload.messageKey),
      let remediation = model.agentPermissionRemediations[taskID],
      remediation.messageKey == messageKey
    else { return }
    model.applyDesktopPermissionRemediation(taskID: taskID, messageKey: messageKey)
  }

  private static func nativePermissionContext(
    _ payload: BridgeDesktopCommandPayload,
    model: BridgeServiceAppModel
  ) -> (String, IPCAgentNativePermissionPolicyResponse)? {
    guard connected(model),
      let installationID = nativePermissionInstallationID(payload.installationID, model: model),
      let snapshot = model.nativePermissionPolicy(installationID: installationID),
      !model.isLoadingNativePermissionPolicy(installationID),
      !model.isSavingNativePermissionPolicy(installationID)
    else { return nil }
    return (installationID, snapshot)
  }

  private static func nativePermissionInstallationID(
    _ requestedID: String?,
    model: BridgeServiceAppModel
  ) -> String? {
    let requested: String?
    if let requestedID {
      guard let value = validatedID(requestedID, maximumBytes: 256) else { return nil }
      requested = value
    } else {
      requested = nil
    }
    return model.agentInstallations.first(where: {
      supportedProviders.contains($0.providerID)
        && $0.isEnabled && $0.availability == "available"
        && (requested == nil || $0.installationID == requested)
    })?.installationID
  }

  private static let supportedProviders: Set<String> = ["antigravity", "pi", "qoder"]

  private static func nativePermissionTarget(_ value: String?) -> String? {
    guard let value = validatedText(value, maximumBytes: 4 * 1_024) else { return nil }
    let target = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty,
      target.rangeOfCharacter(from: .controlCharacters) == nil
    else { return nil }
    return target
  }

  private static func requiresRuleConfirmation(
    providerID: String,
    effect: String,
    action: String,
    target: String
  ) -> Bool {
    guard effect == "allow" else { return false }
    if target.contains("*") || action == "*" { return true }
    if providerID == "pi" { return action == "bash" || action == "powershell" }
    if providerID == "qoder" { return action == "Bash" || action == "MCP" }
    if action == "unsandboxed" { return true }
    if action == "mcp", !target.contains("/") { return true }
    if action == "command", target.split(whereSeparator: \.isWhitespace).count <= 1 {
      return true
    }
    if action == "read_url" || action == "execute_url" {
      let host = target.split(separator: ":", maxSplits: 1).first ?? ""
      return !host.contains(".")
    }
    return false
  }
}

#if os(Windows)
  import BridgeDesktopUI
  import Foundation

  extension WindowsDesktopUICommandRouter {
    static func approvalCommand(
      _ command: BridgeDesktopCommand,
      payload: BridgeDesktopCommandPayload
    ) -> MainWindowCommand? {
      switch command {
      case .resolveApproval:
        guard let approvalID = value(payload.approvalID),
          let taskID = value(payload.taskID),
          let decision = value(payload.decision)
        else { return nil }
        let oneTimeToolAutoApproval = payload.oneTimeToolAutoApproval == true
        guard !oneTimeToolAutoApproval || payload.confirmed == true else { return nil }
        return .resolveTaskApproval(
          approvalID: approvalID,
          taskID: taskID,
          decision: decision,
          oneTimeToolAutoApproval: oneTimeToolAutoApproval,
          answersJSON: value(payload.input)
        )
      case .resolveDirectApproval:
        guard let approvalID = value(payload.approvalID),
          let decision = value(payload.decision)
        else { return nil }
        return .resolveDirectApproval(id: approvalID, decision: decision)
      default:
        return nil
      }
    }

    static func nativePermissionCommand(
      _ command: BridgeDesktopCommand,
      payload: BridgeDesktopCommandPayload
    ) -> MainWindowCommand? {
      switch command {
      case .refreshAgentNativePermission:
        return value(payload.installationID).map {
          .refreshAgentNativePermission(installationID: $0)
        }
      case .setAgentNativePermissionMode:
        guard let installationID = value(payload.installationID),
          let mode = value(payload.toolPermission)
        else { return nil }
        return .setAgentNativePermissionMode(
          installationID: installationID,
          mode: mode,
          confirmed: payload.confirmed == true
        )
      case .addAgentNativePermissionRule:
        guard let installationID = value(payload.installationID),
          let effect = value(payload.effect),
          let action = value(payload.action),
          let target = value(payload.target)
        else { return nil }
        return .addAgentNativePermissionRule(
          installationID: installationID,
          effect: effect,
          action: action,
          target: target,
          confirmed: payload.confirmed == true
        )
      case .replaceAgentNativePermissionRule:
        guard let installationID = value(payload.installationID),
          let ruleID = value(payload.ruleID),
          let effect = value(payload.effect),
          let action = value(payload.action),
          let target = value(payload.target)
        else { return nil }
        return .replaceAgentNativePermissionRule(
          installationID: installationID,
          ruleID: ruleID,
          effect: effect,
          action: action,
          target: target,
          confirmed: payload.confirmed == true
        )
      case .removeAgentNativePermissionRule:
        guard let installationID = value(payload.installationID),
          let ruleID = value(payload.ruleID)
        else { return nil }
        return .removeAgentNativePermissionRule(
          installationID: installationID,
          ruleID: ruleID
        )
      case .prepareAgentPermissionRemediation:
        guard let taskID = value(payload.taskID), let messageKey = value(payload.messageKey)
        else { return nil }
        return .prepareAgentPermissionRemediation(taskID: taskID, messageKey: messageKey)
      case .applyAgentPermissionRemediation:
        guard payload.confirmed == true,
          let taskID = value(payload.taskID),
          let messageKey = value(payload.messageKey)
        else { return nil }
        return .applyAgentPermissionRemediation(
          taskID: taskID,
          messageKey: messageKey,
          confirmed: true
        )
      default:
        return nil
      }
    }

    private static func value(_ rawValue: String?) -> String? {
      guard let rawValue else { return nil }
      let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      return value.isEmpty ? nil : value
    }
  }
#endif

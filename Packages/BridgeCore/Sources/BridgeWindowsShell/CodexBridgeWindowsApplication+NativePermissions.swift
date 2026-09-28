#if os(Windows)
  import BridgeDesktopUI

  extension CodexBridgeWindowsApplication {
    static func runDesktopNativePermissionCommand(
      _ envelope: BridgeDesktopCommandEnvelope,
      model: WindowsWorkbenchModel,
      agentDefaults: WindowsAgentDefaultsModel
    ) -> Bool {
      let payload = envelope.payload
      switch envelope.command {
      case .refreshAgentNativePermission:
        guard let installationID = BridgeDesktopCommandValue.nonEmpty(payload.installationID)
        else { return true }
        Task { @MainActor in
          await agentDefaults.refreshNativePermissionPolicy(installationID: installationID)
        }
      case .setAgentNativePermissionMode:
        guard let installationID = BridgeDesktopCommandValue.nonEmpty(payload.installationID),
          let mode = BridgeDesktopCommandValue.nonEmpty(payload.toolPermission)
        else { return true }
        Task { @MainActor in
          await agentDefaults.setNativePermissionMode(
            installationID: installationID,
            mode: mode,
            confirmed: payload.confirmed == true
          )
        }
      case .addAgentNativePermissionRule:
        guard let installationID = BridgeDesktopCommandValue.nonEmpty(payload.installationID),
          let effect = BridgeDesktopCommandValue.nonEmpty(payload.effect),
          let action = BridgeDesktopCommandValue.nonEmpty(payload.action),
          let target = BridgeDesktopCommandValue.nonEmpty(payload.target)
        else { return true }
        Task { @MainActor in
          await agentDefaults.addNativePermissionRule(
            installationID: installationID,
            effect: effect,
            action: action,
            target: target,
            confirmed: payload.confirmed == true
          )
        }
      case .replaceAgentNativePermissionRule:
        guard let installationID = BridgeDesktopCommandValue.nonEmpty(payload.installationID),
          let ruleID = BridgeDesktopCommandValue.nonEmpty(payload.ruleID),
          let effect = BridgeDesktopCommandValue.nonEmpty(payload.effect),
          let action = BridgeDesktopCommandValue.nonEmpty(payload.action),
          let target = BridgeDesktopCommandValue.nonEmpty(payload.target)
        else { return true }
        Task { @MainActor in
          await agentDefaults.replaceNativePermissionRule(
            installationID: installationID,
            ruleID: ruleID,
            effect: effect,
            action: action,
            target: target,
            confirmed: payload.confirmed == true
          )
        }
      case .removeAgentNativePermissionRule:
        guard let installationID = BridgeDesktopCommandValue.nonEmpty(payload.installationID),
          let ruleID = BridgeDesktopCommandValue.nonEmpty(payload.ruleID)
        else { return true }
        Task { @MainActor in
          await agentDefaults.removeNativePermissionRule(
            installationID: installationID,
            ruleID: ruleID
          )
        }
      case .prepareAgentPermissionRemediation:
        guard let taskID = BridgeDesktopCommandValue.nonEmpty(payload.taskID),
          let messageKey = BridgeDesktopCommandValue.nonEmpty(payload.messageKey)
        else { return true }
        Task { @MainActor in
          await model.preparePermissionRemediation(taskID: taskID, messageKey: messageKey)
        }
      case .applyAgentPermissionRemediation:
        guard payload.confirmed == true,
          let taskID = BridgeDesktopCommandValue.nonEmpty(payload.taskID),
          let messageKey = BridgeDesktopCommandValue.nonEmpty(payload.messageKey)
        else { return true }
        Task { @MainActor in
          let result = await model.applyPermissionRemediation(
            taskID: taskID,
            messageKey: messageKey
          )
          switch result {
          case .applied(let installationID):
            await agentDefaults.refreshNativePermissionPolicy(installationID: installationID)
          case .conflict(let installationID):
            await agentDefaults.refreshNativePermissionPolicy(installationID: installationID)
            selectedPage = .settings
            WindowsUIThread.shared.enqueue {
              WindowsMainWindow.selectPage(.settings)
            }
          case .failed:
            break
          }
        }
      default:
        return false
      }
      return true
    }
  }
#endif

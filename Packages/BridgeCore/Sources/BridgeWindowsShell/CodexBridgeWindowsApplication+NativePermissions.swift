#if os(Windows)
  extension CodexBridgeWindowsApplication {
    static func runNativePermissionCommand(
      _ command: MainWindowCommand,
      model: WindowsWorkbenchModel,
      agentDefaults: WindowsAgentDefaultsModel
    ) -> Bool {
      switch command {
      case .refreshAgentNativePermission(let installationID):
        Task { @MainActor in
          await agentDefaults.refreshNativePermissionPolicy(installationID: installationID)
        }
      case .setAgentNativePermissionMode(let installationID, let mode, let confirmed):
        Task { @MainActor in
          await agentDefaults.setNativePermissionMode(
            installationID: installationID,
            mode: mode,
            confirmed: confirmed
          )
        }
      case .addAgentNativePermissionRule(
        let installationID,
        let effect,
        let action,
        let target,
        let confirmed):
        Task { @MainActor in
          await agentDefaults.addNativePermissionRule(
            installationID: installationID,
            effect: effect,
            action: action,
            target: target,
            confirmed: confirmed
          )
        }
      case .replaceAgentNativePermissionRule(
        let installationID,
        let ruleID,
        let effect,
        let action,
        let target,
        let confirmed):
        Task { @MainActor in
          await agentDefaults.replaceNativePermissionRule(
            installationID: installationID,
            ruleID: ruleID,
            effect: effect,
            action: action,
            target: target,
            confirmed: confirmed
          )
        }
      case .removeAgentNativePermissionRule(let installationID, let ruleID):
        Task { @MainActor in
          await agentDefaults.removeNativePermissionRule(
            installationID: installationID,
            ruleID: ruleID
          )
        }
      case .prepareAgentPermissionRemediation(let taskID, let messageKey):
        Task { @MainActor in
          await model.preparePermissionRemediation(taskID: taskID, messageKey: messageKey)
        }
      case .applyAgentPermissionRemediation(let taskID, let messageKey, let confirmed):
        guard confirmed else { return true }
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

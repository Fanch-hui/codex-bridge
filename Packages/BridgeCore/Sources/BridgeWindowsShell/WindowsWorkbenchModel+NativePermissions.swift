#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore

  enum WindowsPermissionRemediationApplyResult: Equatable {
    case applied(installationID: String)
    case conflict(installationID: String)
    case failed
  }

  extension WindowsWorkbenchModel {
    func preparePermissionRemediation(
      taskID: String,
      messageKey: String
    ) async {
      guard connectionState == .connected,
        let task = tasks.first(where: {
          $0.taskID == taskID && $0.providerID == "antigravity"
            && $0.failureCode == "antigravity_permission_denied"
        }),
        selectedTaskID == nil || selectedTaskID == task.taskID,
        conversation?.entries.contains(where: {
          $0.key == messageKey && $0.kind == "tool_call" && $0.toolStatus == "declined"
        }) == true,
        permissionRemediationLoadingTaskIDs.insert(taskID).inserted
      else { return }
      permissionRemediationAppliedTaskIDs.remove(taskID)
      permissionRemediations.removeValue(forKey: taskID)
      permissionRemediationErrors.removeValue(forKey: taskID)
      publishDisplay()
      defer {
        permissionRemediationLoadingTaskIDs.remove(taskID)
        publishDisplay()
      }
      do {
        let remediation = try await client.agentPermissionRemediation(
          IPCAgentPermissionRemediationRequest(taskID: taskID, messageKey: messageKey)
        )
        guard remediation.taskID == taskID, remediation.messageKey == messageKey else {
          permissionRemediationErrors[taskID] = "权限修复建议与当前任务不匹配。"
          return
        }
        permissionRemediations[taskID] = remediation
      } catch {
        permissionRemediationErrors[taskID] = BridgeServiceErrorMessage.message(error)
      }
    }

    func applyPermissionRemediation(
      taskID: String,
      messageKey: String
    ) async -> WindowsPermissionRemediationApplyResult {
      guard connectionState == .connected,
        let remediation = permissionRemediations[taskID],
        remediation.messageKey == messageKey,
        permissionRemediationApplyingTaskIDs.insert(taskID).inserted
      else { return .failed }
      permissionRemediationErrors.removeValue(forKey: taskID)
      publishDisplay()
      defer {
        permissionRemediationApplyingTaskIDs.remove(taskID)
        publishDisplay()
      }
      do {
        _ = try await client.applyAgentPermissionRemediation(
          IPCAgentPermissionRemediationApplyRequest(
            taskID: remediation.taskID,
            messageKey: remediation.messageKey,
            candidateID: remediation.candidateID,
            expectedRevision: remediation.settingsRevision
          )
        )
        permissionRemediations.removeValue(forKey: taskID)
        permissionRemediationAppliedTaskIDs.insert(taskID)
        feedback.postToast("AGY Global 权限已更新，请重新提交任务")
        return .applied(installationID: remediation.installationID)
      } catch {
        let message = BridgeServiceErrorMessage.message(error)
        permissionRemediationErrors[taskID] = message
        if Self.isPermissionRuleConflict(error) {
          feedback.postAlert(
            "已有 Ask 或 Deny 规则覆盖该目标，请先在设置中处理冲突。",
            title: "AGY Global 规则冲突"
          )
          return .conflict(installationID: remediation.installationID)
        }
        feedback.postAlert(message, title: "AGY Global 权限更新失败")
        return .failed
      }
    }

    func desktopPermissionRemediation(
      for task: MCPServiceTaskSnapshot
    ) -> BridgeDesktopPermissionRemediationState? {
      guard task.providerID == "antigravity",
        task.failureCode == "antigravity_permission_denied",
        let entry = conversation?.entries.last(where: {
          $0.kind == "tool_call" && $0.toolStatus == "declined"
        })
      else { return nil }
      let response = permissionRemediations[task.taskID].flatMap {
        $0.messageKey == entry.key ? $0 : nil
      }
      return BridgeDesktopPermissionRemediationState(
        messageKey: entry.key,
        installationID: response?.installationID,
        candidateID: response?.candidateID,
        action: response?.action,
        target: response?.target,
        displayRule: response?.displayRule,
        requiresConfirmation: response?.requiresConfirmation ?? false,
        isLoading: permissionRemediationLoadingTaskIDs.contains(task.taskID),
        isApplying: permissionRemediationApplyingTaskIDs.contains(task.taskID),
        didApply: permissionRemediationAppliedTaskIDs.contains(task.taskID),
        errorMessage: permissionRemediationErrors[task.taskID]
      )
    }

    private static func isPermissionRuleConflict(_ error: any Error) -> Bool {
      guard let codecError = error as? BridgeServiceIPCCodecError,
        case .remoteError(let remote) = codecError
      else { return false }
      return remote.code == "agent_permission_rule_invalid"
    }
  }
#endif

import BridgeIPC
import Foundation

extension BridgeServiceAppModel {
  func nativePermissionPolicy(
    installationID: String
  ) -> IPCAgentNativePermissionPolicyResponse? {
    agentNativePermissionPolicies[installationID]
  }

  func loadNativePermissionPolicy(installationID: String) async {
    guard !installationID.isEmpty else { return }
    let generation = incrementNativePermissionGeneration(for: installationID)
    agentNativePermissionLoadingInstallations.insert(installationID)
    agentNativePermissionErrors.removeValue(forKey: installationID)
    defer {
      if agentNativePermissionGenerations[installationID] == generation {
        agentNativePermissionLoadingInstallations.remove(installationID)
      }
    }
    do {
      let client = try currentClient()
      let snapshot = try await client.agentNativePermissionPolicy(
        installationID: installationID
      )
      guard agentNativePermissionGenerations[installationID] == generation else { return }
      agentNativePermissionPolicies[installationID] = snapshot
    } catch {
      guard agentNativePermissionGenerations[installationID] == generation else { return }
      agentNativePermissionErrors[installationID] = Self.message(error)
    }
  }

  func updateNativePermissionPolicy(
    _ request: IPCAgentNativePermissionMutationRequest
  ) {
    let installationID = request.installationID
    guard agentNativePermissionSavingInstallations.insert(installationID).inserted else {
      return
    }
    let generation = incrementNativePermissionGeneration(for: installationID)
    agentNativePermissionErrors.removeValue(forKey: installationID)
    Task { [weak self] in
      guard let self else { return }
      defer {
        if self.agentNativePermissionGenerations[installationID] == generation {
          self.agentNativePermissionSavingInstallations.remove(installationID)
        }
      }
      do {
        let client = try self.currentClient()
        let snapshot = try await client.updateAgentNativePermissionPolicy(request)
        guard self.agentNativePermissionGenerations[installationID] == generation else { return }
        self.agentNativePermissionPolicies[installationID] = snapshot
        self.postToast("AGY Global 权限已更新", symbol: "checkmark.shield.fill", tone: .success)
      } catch {
        guard self.agentNativePermissionGenerations[installationID] == generation else { return }
        self.agentNativePermissionErrors[installationID] = Self.message(error)
        await self.reloadNativePermissionPolicyAfterFailedMutation(
          installationID: installationID,
          generation: generation
        )
      }
    }
  }

  func isLoadingNativePermissionPolicy(_ installationID: String) -> Bool {
    agentNativePermissionLoadingInstallations.contains(installationID)
  }

  func isSavingNativePermissionPolicy(_ installationID: String) -> Bool {
    agentNativePermissionSavingInstallations.contains(installationID)
  }

  func permissionRemediation(
    taskID: String,
    messageKey: String
  ) async -> IPCAgentPermissionRemediationResponse? {
    do {
      return try await currentClient().agentPermissionRemediation(
        IPCAgentPermissionRemediationRequest(
          taskID: taskID,
          messageKey: messageKey
        )
      )
    } catch {
      errorMessage = Self.message(error)
      return nil
    }
  }

  func applyPermissionRemediation(
    _ remediation: IPCAgentPermissionRemediationResponse
  ) async -> Bool {
    do {
      let snapshot = try await currentClient().applyAgentPermissionRemediation(
        IPCAgentPermissionRemediationApplyRequest(
          taskID: remediation.taskID,
          messageKey: remediation.messageKey,
          candidateID: remediation.candidateID,
          expectedRevision: remediation.settingsRevision
        )
      )
      agentNativePermissionPolicies[snapshot.installationID] = snapshot
      postToast(
        "AGY Global 权限已更新，请重新提交任务",
        symbol: "checkmark.shield.fill",
        tone: .success
      )
      return true
    } catch {
      if await openNativePermissionConflict(remediation, error: error) {
        return false
      }
      errorMessage = Self.message(error)
      return false
    }
  }

  private func openNativePermissionConflict(
    _ remediation: IPCAgentPermissionRemediationResponse,
    error: any Error
  ) async -> Bool {
    guard let codecError = error as? BridgeServiceIPCCodecError,
      case .remoteError(let remote) = codecError,
      remote.code == "agent_permission_rule_invalid",
      let client = try? currentClient(),
      let policy = try? await client.agentNativePermissionPolicy(
        installationID: remediation.installationID
      ),
      policy.rules.contains(where: {
        $0.action == remediation.action && $0.target == remediation.target
          && ($0.effect == "ask" || $0.effect == "deny")
      })
    else { return false }
    agentNativePermissionPolicies[policy.installationID] = policy
    agentNativePermissionErrors[policy.installationID] =
      "已有 Ask 或 Deny 规则覆盖该目标，请先在此处处理冲突。"
    focusedAgentNativePermissionInstallationID = policy.installationID
    selection = .settings
    postToast("请先处理 AGY Global 规则冲突", symbol: "exclamationmark.shield", tone: .warning)
    return true
  }

  private func reloadNativePermissionPolicyAfterFailedMutation(
    installationID: String,
    generation: UInt64
  ) async {
    guard let client = try? currentClient(),
      let snapshot = try? await client.agentNativePermissionPolicy(
        installationID: installationID
      ),
      agentNativePermissionGenerations[installationID] == generation
    else { return }
    agentNativePermissionPolicies[installationID] = snapshot
  }

  @discardableResult
  private func incrementNativePermissionGeneration(for installationID: String) -> UInt64 {
    let next = (agentNativePermissionGenerations[installationID] ?? 0) &+ 1
    agentNativePermissionGenerations[installationID] = next
    return next
  }
}

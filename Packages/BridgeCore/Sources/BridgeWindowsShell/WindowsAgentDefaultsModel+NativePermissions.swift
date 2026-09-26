#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeServiceAppCore
  import Foundation

  extension WindowsAgentDefaultsModel {
    func refreshNativePermissionPolicy(installationID requestedID: String? = nil) async {
      guard connectionState == .connected, !nativePermissionLoading, !nativePermissionSaving else {
        return
      }
      guard let installation = nativePermissionInstallation(requestedID) else {
        nativePermissionInstallationID = nil
        nativePermissionPolicy = nil
        nativePermissionError = nil
        publishDisplay()
        return
      }
      nativePermissionInstallationID = installation.installationID
      nativePermissionLoading = true
      nativePermissionError = nil
      publishDisplay()
      defer {
        nativePermissionLoading = false
        publishDisplay()
      }
      do {
        let snapshot = try await client.agentNativePermissionPolicy(
          installationID: installation.installationID
        )
        guard snapshot.installationID == installation.installationID,
          snapshot.providerID == installation.providerID
        else {
          nativePermissionError = "原生权限响应与当前安装不匹配。"
          return
        }
        nativePermissionPolicy = snapshot
      } catch {
        nativePermissionError = "原生权限读取失败：\(BridgeServiceErrorMessage.message(error))"
      }
    }

    func updateNativePermissionPolicy(
      _ request: IPCAgentNativePermissionMutationRequest
    ) async {
      guard connectionState == .connected, !nativePermissionLoading, !nativePermissionSaving,
        let current = nativePermissionPolicy,
        current.installationID == request.installationID,
        current.revision == request.expectedRevision,
        nativePermissionInstallation(request.installationID) != nil
      else { return }
      nativePermissionSaving = true
      nativePermissionError = nil
      publishDisplay()
      defer {
        nativePermissionSaving = false
        publishDisplay()
      }
      do {
        let snapshot = try await client.updateAgentNativePermissionPolicy(request)
        guard snapshot.installationID == request.installationID,
          snapshot.providerID == current.providerID
        else {
          nativePermissionError = "原生权限响应与当前安装不匹配。"
          return
        }
        nativePermissionPolicy = snapshot
        feedback.postToast("\(nativePermissionTitle(current.providerID)) 权限已更新")
      } catch {
        nativePermissionError = "原生权限保存失败：\(BridgeServiceErrorMessage.message(error))"
        if let snapshot = try? await client.agentNativePermissionPolicy(
          installationID: request.installationID
        ) {
          nativePermissionPolicy = snapshot
        }
        feedback.postAlert(nativePermissionError ?? "原生权限保存失败。")
      }
    }

    func setNativePermissionMode(
      installationID: String,
      mode: String,
      confirmed: Bool
    ) async {
      guard let snapshot = nativePermissionMutationContext(installationID),
        let option = snapshot.availableModes.first(where: { $0.modeID == mode }),
        !option.requiresConfirmation || confirmed
      else { return }
      await updateNativePermissionPolicy(
        IPCAgentNativePermissionMutationRequest(
          installationID: installationID,
          expectedRevision: snapshot.revision,
          operation: .setToolPermission,
          toolPermission: mode
        )
      )
    }

    func addNativePermissionRule(
      installationID: String,
      effect: String,
      action: String,
      target: String,
      confirmed: Bool
    ) async {
      guard let snapshot = nativePermissionMutationContext(installationID),
        Self.validEffects.contains(effect),
        snapshot.availableActions.contains(action),
        let normalizedTarget = Self.validatedTarget(target),
        !Self.requiresRuleConfirmation(
          providerID: snapshot.providerID,
          effect: effect,
          action: action,
          target: normalizedTarget
        ) || confirmed
      else { return }
      await updateNativePermissionPolicy(
        IPCAgentNativePermissionMutationRequest(
          installationID: installationID,
          expectedRevision: snapshot.revision,
          operation: .addRule,
          effect: effect,
          action: action,
          target: normalizedTarget
        )
      )
    }

    func replaceNativePermissionRule(
      installationID: String,
      ruleID: String,
      effect: String,
      action: String,
      target: String,
      confirmed: Bool
    ) async {
      guard let snapshot = nativePermissionMutationContext(installationID),
        let rule = snapshot.rules.first(where: { $0.ruleID == ruleID }),
        rule.isEditable,
        Self.validEffects.contains(effect),
        snapshot.availableActions.contains(action),
        let normalizedTarget = Self.validatedTarget(target),
        (!rule.requiresConfirmation
          && !Self.requiresRuleConfirmation(
            providerID: snapshot.providerID,
            effect: effect,
            action: action,
            target: normalizedTarget
          )) || confirmed
      else { return }
      await updateNativePermissionPolicy(
        IPCAgentNativePermissionMutationRequest(
          installationID: installationID,
          expectedRevision: snapshot.revision,
          operation: .replaceRule,
          ruleID: ruleID,
          effect: effect,
          action: action,
          target: normalizedTarget
        )
      )
    }

    func removeNativePermissionRule(
      installationID: String,
      ruleID: String
    ) async {
      guard let snapshot = nativePermissionMutationContext(installationID),
        snapshot.rules.contains(where: { $0.ruleID == ruleID && $0.isEditable })
      else { return }
      await updateNativePermissionPolicy(
        IPCAgentNativePermissionMutationRequest(
          installationID: installationID,
          expectedRevision: snapshot.revision,
          operation: .removeRule,
          ruleID: ruleID
        )
      )
    }

    func desktopNativePermissionPolicy() -> BridgeDesktopNativePermissionState? {
      guard let installation = nativePermissionInstallation(nativePermissionInstallationID) else {
        return nil
      }
      let snapshot = nativePermissionPolicy.flatMap {
        $0.installationID == installation.installationID ? $0 : nil
      }
      return BridgeDesktopNativePermissionState(
        providerID: installation.providerID,
        providerName: providers.first(where: { $0.providerID == installation.providerID })?
          .displayName ?? installation.providerID,
        installationID: installation.installationID,
        installationName: installation.displayName,
        installations: installations.filter {
          Self.supportedProviders.contains($0.providerID)
            && $0.isEnabled && $0.availability == "available"
        }.map {
          BridgeDesktopChoice(id: $0.installationID, title: $0.displayName)
        },
        toolPermission: snapshot?.toolPermission,
        availableModes: snapshot?.availableModes.map {
          BridgeDesktopNativePermissionMode(
            modeID: $0.modeID,
            displayName: $0.displayName,
            requiresConfirmation: $0.requiresConfirmation
          )
        } ?? [],
        availableActions: snapshot?.availableActions ?? [],
        rules: snapshot?.rules.map {
          BridgeDesktopNativePermissionRule(
            ruleID: $0.ruleID,
            effect: $0.effect,
            action: $0.action,
            target: $0.target,
            isEditable: $0.isEditable,
            isRedacted: $0.isRedacted,
            requiresConfirmation: $0.requiresConfirmation
          )
        } ?? [],
        warnings: snapshot?.warnings ?? [],
        isLoading: nativePermissionLoading,
        isSaving: nativePermissionSaving,
        canEdit: connectionState == .connected && snapshot != nil
          && !nativePermissionLoading && !nativePermissionSaving,
        errorMessage: nativePermissionError
      )
    }

    private func nativePermissionInstallation(
      _ requestedID: String?
    ) -> IPCAgentInstallationSummary? {
      installations.first {
        Self.supportedProviders.contains($0.providerID)
          && $0.isEnabled && $0.availability == "available"
          && (requestedID == nil || $0.installationID == requestedID)
      }
    }

    private func nativePermissionMutationContext(
      _ installationID: String
    ) -> IPCAgentNativePermissionPolicyResponse? {
      guard connectionState == .connected, !nativePermissionLoading, !nativePermissionSaving,
        let snapshot = nativePermissionPolicy,
        snapshot.installationID == installationID,
        nativePermissionInstallation(installationID) != nil
      else { return nil }
      return snapshot
    }

    private static let validEffects = ["allow", "ask", "deny"]
    private static let supportedProviders: Set<String> = ["antigravity", "pi", "qoder"]

    private static func validatedTarget(_ value: String) -> String? {
      let target = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !target.isEmpty, target.utf8.count <= 4 * 1_024, !target.contains("\0"),
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

    private func nativePermissionTitle(_ providerID: String) -> String {
      providers.first(where: { $0.providerID == providerID })?.displayName ?? providerID
    }
  }
#endif

#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeServiceAppCore

  extension WindowsManagementModel {
    func handleAgentSetupCommand(_ envelope: BridgeDesktopCommandEnvelope) async -> Bool {
      guard connectionState == .connected else { return false }
      let payload = envelope.payload
      if [.beginAgentSetup, .continueAgentSetup, .cancelAgentSetup].contains(envelope.command) {
        agentSetupRequestGeneration &+= 1
      }
      do {
        switch envelope.command {
        case .refreshAgentSetups:
          return await refreshAgentSetups()
        case .beginAgentSetup:
          guard let providerID = BridgeDesktopCommandValue.nonEmpty(payload.providerID),
            providerID != "codex", agentProviders.contains(where: { $0.providerID == providerID })
          else { return false }
          let distribution = BridgeDesktopCommandValue.qoderDistribution(payload.qoderDistribution)
          guard providerID != "qoder" || distribution != nil else { return false }
          let value = try await client.beginAgentSetup(
            IPCAgentSetupRequest(
              providerID: providerID, qoderDistribution: distribution,
              installationID: BridgeDesktopCommandValue.nonEmpty(payload.installationID),
              installDirectory: BridgeDesktopCommandValue.nonEmpty(payload.installDirectory)))
          return await applyAgentSetup(value)
        case .continueAgentSetup:
          guard let id = BridgeDesktopCommandValue.nonEmpty(payload.operationID) else {
            return false
          }
          let value = try await client.continueAgentSetup(
            IPCAgentSetupContinueRequest(
              operationID: id,
              installationID: BridgeDesktopCommandValue.nonEmpty(payload.installationID),
              baseURL: AgentConnectionInput.baseURL(payload.baseURL),
              apiKey: AgentConnectionInput.apiKey(payload.apiKey),
              inferenceProtocol: payload.inferenceProtocol,
              catalogBaseURL: AgentConnectionInput.baseURL(payload.catalogBaseURL),
              alwaysProceedConfirmed: payload.confirmed == true))
          return await applyAgentSetup(value)
        case .cancelAgentSetup:
          guard let id = BridgeDesktopCommandValue.nonEmpty(payload.operationID) else {
            return false
          }
          return await applyAgentSetup(try await client.cancelAgentSetup(operationID: id))
        case .openAgentSetupLogin:
          guard let id = BridgeDesktopCommandValue.nonEmpty(payload.operationID),
            let value = try await client.agentSetups().first(where: { $0.operationID == id }),
            value.state == "needs_user_action", let command = value.loginCommand
          else { return false }
          do {
            try AgentSetupLoginLauncher.open(command)
          } catch {
            let fallback = try AgentSetupLoginLauncher.manualCommand(command)
            let copied = DesktopPlatformHost.copy(fallback)
            reportAgentFailure(
              copied
                ? "无法打开登录终端。登录命令已复制，请在终端中粘贴执行，完成后返回检测。"
                : "无法打开登录终端，请参考官方登录说明完成操作。")
          }
        default: return false
        }
      } catch { reportAgentFailure(BridgeServiceErrorMessage.message(error)) }
      return false
    }

    @discardableResult
    func refreshAgentSetups() async -> Bool {
      guard !agentSetupRefreshInFlight else { return false }
      agentSetupRefreshInFlight = true
      let generation = agentSetupRequestGeneration
      defer { agentSetupRefreshInFlight = false }
      do {
        let values = try await client.agentSetups()
        guard generation == agentSetupRequestGeneration else { return false }
        var becameReady = false
        for value in values {
          if await applyAgentSetup(value) { becameReady = true }
        }
        guard generation == agentSetupRequestGeneration else { return false }
        agentSetupOperations = values
        publishDisplay()
        return becameReady
      } catch { reportAgentFailure(BridgeServiceErrorMessage.message(error)) }
      return false
    }

    private func applyAgentSetup(_ value: IPCAgentSetupState) async -> Bool {
      let previous = agentSetupOperations.first { $0.operationID == value.operationID }
      if let index = agentSetupOperations.firstIndex(where: { $0.operationID == value.operationID })
      {
        agentSetupOperations[index] = value
      } else {
        agentSetupOperations.append(value)
      }
      publishDisplay()
      guard value.state == "ready", previous?.state != "ready" else { return false }
      await refreshAgents()
      return true
    }
  }
#endif

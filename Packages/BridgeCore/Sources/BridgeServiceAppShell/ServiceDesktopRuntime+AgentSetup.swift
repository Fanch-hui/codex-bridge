import AppKit
import BridgeDesktopUI
import BridgeIPC
import BridgeServiceAppCore

extension BridgeServiceAppModel {
  func handleAgentSetupCommand(_ envelope: BridgeDesktopCommandEnvelope) {
    guard connectionState == .connected else { return }
    Task { [weak self] in
      guard let self else { return }
      do {
        let client = try currentClient()
        let payload = envelope.payload
        if [.beginAgentSetup, .continueAgentSetup, .cancelAgentSetup].contains(envelope.command) {
          agentSetupRequestGeneration &+= 1
        }
        switch envelope.command {
        case .refreshAgentSetups:
          await refreshAgentSetups(client: client)
        case .beginAgentSetup:
          guard let providerID = BridgeDesktopCommandValue.nonEmpty(payload.providerID),
            providerID != "codex", agentProviders.contains(where: { $0.providerID == providerID })
          else { return }
          let distribution = BridgeDesktopCommandValue.qoderDistribution(payload.qoderDistribution)
          guard providerID != "qoder" || distribution != nil else { return }
          let value = try await client.beginAgentSetup(
            IPCAgentSetupRequest(
              providerID: providerID, qoderDistribution: distribution,
              installationID: BridgeDesktopCommandValue.nonEmpty(payload.installationID),
              installDirectory: BridgeDesktopCommandValue.nonEmpty(payload.installDirectory)))
          await applyAgentSetup(value, client: client)
        case .continueAgentSetup:
          guard let id = BridgeDesktopCommandValue.nonEmpty(payload.operationID) else { return }
          let value = try await client.continueAgentSetup(
            IPCAgentSetupContinueRequest(
              operationID: id,
              installationID: BridgeDesktopCommandValue.nonEmpty(payload.installationID),
              baseURL: AgentConnectionInput.baseURL(payload.baseURL),
              apiKey: AgentConnectionInput.apiKey(payload.apiKey),
              inferenceProtocol: payload.inferenceProtocol,
              catalogBaseURL: AgentConnectionInput.baseURL(payload.catalogBaseURL),
              alwaysProceedConfirmed: payload.confirmed == true))
          await applyAgentSetup(value, client: client)
        case .cancelAgentSetup:
          guard let id = BridgeDesktopCommandValue.nonEmpty(payload.operationID) else { return }
          await applyAgentSetup(try await client.cancelAgentSetup(operationID: id), client: client)
        case .openAgentSetupLogin:
          guard let id = BridgeDesktopCommandValue.nonEmpty(payload.operationID),
            let value = try await client.agentSetups().first(where: { $0.operationID == id }),
            value.state == "needs_user_action", let command = value.loginCommand
          else { return }
          do {
            try AgentSetupLoginLauncher.open(command)
          } catch {
            let fallback = try AgentSetupLoginLauncher.manualCommand(command)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(fallback, forType: .string)
            errorMessage = "无法打开登录终端。登录命令已复制，请在终端中粘贴执行，完成后返回检测。"
          }
        default: return
        }
      } catch { errorMessage = Self.message(error) }
    }
  }

  func refreshAgentSetups(client: any BridgeServiceClientProtocol) async {
    guard !agentSetupRefreshInFlight else { return }
    agentSetupRefreshInFlight = true
    let generation = agentSetupRequestGeneration
    defer { agentSetupRefreshInFlight = false }
    do {
      let values = try await client.agentSetups()
      guard generation == agentSetupRequestGeneration else { return }
      for value in values { await applyAgentSetup(value, client: client) }
      guard generation == agentSetupRequestGeneration else { return }
      agentSetupOperations = values
    } catch { errorMessage = Self.message(error) }
  }

  private func applyAgentSetup(
    _ value: IPCAgentSetupState, client: any BridgeServiceClientProtocol
  ) async {
    let previous = agentSetupOperations.first { $0.operationID == value.operationID }
    if let index = agentSetupOperations.firstIndex(where: { $0.operationID == value.operationID }) {
      agentSetupOperations[index] = value
    } else {
      agentSetupOperations.append(value)
    }
    guard value.state == "ready", previous?.state != "ready" else { return }
    if let catalog = try? await client.agentCatalog() { applyAgentCatalogSnapshot(catalog) }
    refreshAgentModelCatalog(installationID: value.installationID, providerID: value.providerID)
  }
}

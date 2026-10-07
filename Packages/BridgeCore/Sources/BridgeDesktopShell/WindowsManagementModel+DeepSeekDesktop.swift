#if os(Windows) || os(Linux)
  import BridgeAgentCore
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore
  import Foundation

  extension WindowsManagementModel {
    func refreshDeepSeekDesktopStates() async {
      guard !deepSeekDesktopRefreshInFlight else { return }
      deepSeekDesktopRefreshInFlight = true
      defer { deepSeekDesktopRefreshInFlight = false }
      let installations = agentInstallations.filter { $0.providerID == "deepseek-harness-desktop" }
      for installation in installations {
        if let value = try? await client.manageDeepSeekHarnessDesktop(
          .init(installationID: installation.installationID))
        {
          applyDeepSeekDesktop(value, installationID: installation.installationID)
        }
      }
      publishDisplay()
    }

    func manageDeepSeekDesktop(_ payload: BridgeDesktopCommandPayload) async {
      if payload.action == "discover" {
        await discoverDeepSeekDesktop()
        return
      }
      guard !agentBusy, connectionState == .connected,
        let installationID = BridgeDesktopCommandValue.nonEmpty(payload.installationID),
        agentInstallations.contains(where: {
          $0.installationID == installationID && $0.providerID == "deepseek-harness-desktop"
        }), let action = DeepSeekHarnessDesktopAction(rawValue: payload.action ?? "status"),
        action != .openSession
      else { return }
      let mode = payload.mode.flatMap(DeepSeekHarnessConnectionMode.init(rawValue:))
      guard action != .setMode || mode != nil else { return }
      agentBusy = true
      publishDisplay()
      do {
        let value = try await DeepSeekDesktopConnection.perform(
          .init(installationID: installationID, action: action, mode: mode), client: client,
          launchApplication: { try DesktopPlatformHost.openDeepSeekDesktop(executablePath: $0) })
        applyDeepSeekDesktop(value, installationID: installationID)
        agentBusy = false
        agentOperationRevision &+= 1
        await refreshAgents()
      } catch {
        agentBusy = false
        reportAgentFailure(BridgeServiceErrorMessage.message(error))
        if let current = try? await client.manageDeepSeekHarnessDesktop(
          .init(installationID: installationID))
        {
          applyDeepSeekDesktop(current, installationID: installationID)
        }
      }
      publishDisplay()
    }

    private func discoverDeepSeekDesktop() async {
      guard !agentBusy, connectionState == .connected else { return }
      agentBusy = true
      publishDisplay()
      do {
        let installation = try await client.connectAgentInstallation(
          .init(
            providerID: "deepseek-harness-desktop", connectionMode: "native-desktop"))
        let value = try await client.manageDeepSeekHarnessDesktop(
          .init(
            installationID: installation.installationID))
        applyDeepSeekDesktop(value, installationID: installation.installationID)
        agentBusy = false
        agentOperationRevision &+= 1
        await refreshAgents()
      } catch {
        agentBusy = false
        reportAgentFailure(BridgeServiceErrorMessage.message(error))
      }
      publishDisplay()
    }

    func openDeepSeekDesktopSession(
      _ payload: BridgeDesktopCommandPayload,
      task: MCPServiceTaskSnapshot?
    ) async {
      let installationID = task?.installationID ?? payload.installationID
      let projectID = task?.projectID ?? payload.projectID
      let sessionID = task?.threadID ?? payload.sessionID
      guard let installationID, let projectID, task != nil || sessionID != nil,
        agentInstallations.contains(where: {
          $0.installationID == installationID
            && ($0.providerID == "deepseek-harness-desktop"
              || (task != nil && $0.providerID == "deepseek-harness"))
        })
      else { return }
      do {
        var value = try await client.manageDeepSeekHarnessDesktop(
          .init(installationID: installationID))
        guard value.canOpenSession else { throw BridgeServiceClientError.unavailable }
        if !value.desktop.connected {
          try DesktopPlatformHost.openDeepSeekDesktop(executablePath: value.executablePath)
          for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(500))
            value = try await client.manageDeepSeekHarnessDesktop(
              .init(installationID: installationID))
            if value.desktop.connected { break }
          }
        }
        _ = try await client.manageDeepSeekHarnessDesktop(
          .init(
            installationID: installationID,
            action: .openSession, projectID: projectID, sessionID: sessionID, taskID: task?.taskID))
        try DesktopPlatformHost.openDeepSeekDesktop(executablePath: value.executablePath)
      } catch { reportAgentFailure(BridgeServiceErrorMessage.message(error)) }
    }

    private func applyDeepSeekDesktop(_ value: DeepSeekHarnessDesktopState, installationID: String)
    {
      deepSeekDesktopStates[installationID] = .init(
        installationID: installationID,
        mode: value.mode.rawValue, connected: value.desktop.connected, paired: value.desktop.paired,
        pairingCode: value.desktop.pairingCode, profileID: value.desktop.profileID,
        message: value.desktop.unavailableReason,
        executablePath: value.executablePath, connectorInstalled: value.connectorInstalled,
        canInstallConnector: value.canInstallConnector)
    }
  }
#endif

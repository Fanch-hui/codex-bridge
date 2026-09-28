#if os(Windows)
  import BridgeDesktopUI
  import Foundation

  extension CodexBridgeWindowsApplication {
    static func runDesktopCommand(
      _ command: MainWindowCommand,
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) -> Bool {
      switch command {
      case .desktopCommand(let envelope):
        return runDesktopUICommand(
          envelope,
          model: model,
          management: management,
          auxiliary: auxiliary
        )
      case .registerAgentFromDesktop(
        let providerID,
        let displayName,
        let executablePath,
        let configurationPath,
        let qoderDistribution):
        return registerAgentFromDesktop(
          providerID: providerID,
          displayName: displayName,
          executablePath: executablePath,
          configurationPath: configurationPath,
          qoderDistribution: qoderDistribution,
          management: management,
          auxiliary: auxiliary
        )
      default:
        return false
      }
    }

    private static func runDesktopUICommand(
      _ envelope: BridgeDesktopCommandEnvelope,
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) -> Bool {
      runDesktopWindowCommand(envelope, model: model, management: management, auxiliary: auxiliary)
        || runDesktopWorkbenchCommand(
          envelope,
          model: model,
          management: management,
          auxiliary: auxiliary
        )
        || runDesktopProjectCommand(
          envelope,
          model: model,
          management: management,
          auxiliary: auxiliary
        )
        || runDesktopConnectionCommand(envelope, management: management, auxiliary: auxiliary)
        || runDesktopNativePermissionCommand(
          envelope,
          model: model,
          agentDefaults: auxiliary.agentDefaults
        )
        || runDesktopSettingsCommand(envelope, auxiliary: auxiliary)
        || runDesktopLogCommand(envelope, auxiliary: auxiliary)
    }

    private static func runDesktopWindowCommand(
      _ envelope: BridgeDesktopCommandEnvelope,
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) -> Bool {
      let payload = envelope.payload
      switch envelope.command {
      case .refresh:
        refreshAll(model: model, management: management, auxiliary: auxiliary)
      case .checkAppUpdate:
        appUpdater?.check()
      case .installAppUpdate:
        appUpdater?.install()
      case .deferAppUpdate:
        appUpdater?.deferUpdate()
      case .refreshModels:
        Task { @MainActor in await auxiliary.refreshModels(model: model) }
      case .setCodexExecutable:
        guard
          let path = BridgeDesktopCommandValue.pathText(
            payload.path,
            maximumUTF8Bytes: BridgeDesktopCommandValue.maximumExecutablePathBytes
          )
        else { return true }
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
          await auxiliary.connections.setCodexExecutablePath(path)
          await auxiliary.refreshModels(model: model)
        }
      case .scanAgents:
        Task { @MainActor in await management.refreshAgents(forceRefresh: true) }
      case .selectPage:
        guard let navigation = payload.navigation else { return true }
        selectPage(
          WindowsMainPage(navigation), model: model, management: management, auxiliary: auxiliary)
      case .openWorkbench:
        selectPage(.workbench, model: model, management: management, auxiliary: auxiliary)
      case .openProjects:
        selectPage(.projects, model: model, management: management, auxiliary: auxiliary)
      case .openConnections:
        selectPage(.connections, model: model, management: management, auxiliary: auxiliary)
      case .openSettings:
        selectPage(.settings, model: model, management: management, auxiliary: auxiliary)
      case .openLogs:
        selectPage(.logs, model: model, management: management, auxiliary: auxiliary)
      case .openExternalURL:
        guard let url = BridgeDesktopExternalURL.resolve(payload.value) else { return true }
        onUI { openExternalURL(url.absoluteString) }
      case .copyTunnelID:
        guard let id = model.serviceStatus?.tunnel.tunnelID, !id.isEmpty else { return true }
        if WindowsClipboard.write(id, owner: WindowsMainWindow.currentWindow()) {
          management.feedback.postToast("已复制 Tunnel ID")
        } else {
          management.feedback.postAlert("无法复制 Tunnel ID")
        }
      case .updateBrowserViewport:
        guard let viewport = payload.viewport else { return true }
        WindowsMainWindow.applyBrowserViewport(viewport)
      case .dismissFeedback:
        guard let feedbackID = BridgeDesktopCommandValue.nonEmpty(payload.feedbackID) else {
          return true
        }
        model.feedback.dismiss(id: feedbackID)
      default:
        return false
      }
      return true
    }

    static func selectPage(
      _ page: WindowsMainPage,
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) {
      selectedPage = page
      onUI { WindowsMainWindow.selectPage(page) }
      refresh(page: page, model: model, management: management, auxiliary: auxiliary)
    }
  }
#endif

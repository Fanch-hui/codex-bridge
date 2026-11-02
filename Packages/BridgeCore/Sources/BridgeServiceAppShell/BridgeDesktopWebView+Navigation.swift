import BridgeDesktopUI

extension BridgeDesktopWebView.Coordinator {
  func route(_ envelope: BridgeDesktopCommandEnvelope, model: BridgeServiceAppModel) {
    let navigation = envelope.command == .selectPage ? envelope.payload.navigation : nil
    let settingsRequested = envelope.command == .openSettings || navigation == .settings
    let logsRequested = envelope.command == .openLogs || navigation == .logs
    if settingsRequested || logsRequested {
      model.preferencesNavigation = settingsRequested ? .settings : .logs
      if settingsRequested { BridgeDesktopCommandRouter.loadNativePermissionPolicyIfNeeded(model) }
      if surface == .main {
        let detail = destination(envelope, kind: "settings-detail", target: .settingsDetail)
        BridgeDesktopWindowCoordinator.shared.openPreferences(destination: detail)
      }
      return
    }

    if surface == .preferences {
      switch envelope.command {
      case .updateBrowserViewport, .embeddedDSH, .workbenchWorkspace:
        return
      case .refresh, .refreshLogs:
        Task { await model.refreshCurrentPage(model.preferencesNavigation) }
        return
      case .openWorkbenchSession:
        guard let id = BridgeDesktopCommandRouter.validatedID(envelope.payload.sessionID) else {
          return
        }
        model.selection = .workbench
        BridgeDesktopWindowCoordinator.shared.openMain(
          destination: .init(kind: .workbenchSession, value: id))
        return
      case .selectPage, .openWorkbench, .openProjects, .openConnections, .openTask,
        .openThread, .continueNativeAgentSession, .openDeepSeekHarnessSession:
        BridgeDesktopCommandRouter.handle(envelope, model: model)
        let detail: BridgeDesktopWindowDestination?
        if navigation == .workbench {
          detail = destination(envelope, kind: "dsh-settings", target: .dshSettings)
        } else if navigation == .connections {
          detail = destination(envelope, kind: "connection-detail", target: .connectionDetail)
        } else {
          detail = nil
        }
        BridgeDesktopWindowCoordinator.shared.openMain(destination: detail)
        return
      default:
        break
      }
    }
    BridgeDesktopCommandRouter.handle(envelope, model: model)
  }

  private func destination(
    _ envelope: BridgeDesktopCommandEnvelope,
    kind: String,
    target: BridgeDesktopWindowDestination.Kind
  ) -> BridgeDesktopWindowDestination? {
    guard envelope.payload.kind == kind,
      let value = BridgeDesktopCommandRouter.validatedID(envelope.payload.value, maximumBytes: 256)
    else { return nil }
    if target == .dshSettings,
      !["models", "skills", "plugins", "mcp", "permissions"].contains(value)
    {
      return nil
    }
    return BridgeDesktopWindowDestination(kind: target, value: value)
  }
}

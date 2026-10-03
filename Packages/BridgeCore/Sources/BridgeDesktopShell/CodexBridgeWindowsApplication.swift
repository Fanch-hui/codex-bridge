#if os(Windows) || os(Linux)
  import Foundation
  #if os(Windows)
    import WinSDK
  #endif

  /// Shared desktop coordinator. Platform event loops own their native surfaces.
  @MainActor
  public enum CodexBridgeDesktopApplication {
    static var selectedPage = WindowsMainPage.overview

    #if os(Windows)
      public static func main() async {
        WindowsServiceRegistration.migrateLegacyRegistration()
        let feedback = WindowsDesktopFeedbackStore()
        let model = WindowsWorkbenchModel(feedback: feedback)
        let management = WindowsManagementModel(client: model.client, feedback: feedback)
        let auxiliary = WindowsAuxiliaryRuntime(client: model.client, feedback: feedback)
        startAppUpdateCheck(model: model)
        model.onConnected = { [weak model, weak management, weak auxiliary] in
          guard let model, !model.isShuttingDown,
            let management, let auxiliary
          else { return }
          await management.refreshProjects()
          guard !model.isShuttingDown else { return }
          Task(priority: .utility) {
            await management.refreshAgents()
            guard !model.isShuttingDown else { return }
            await auxiliary.agentDefaults.refresh()
          }
          if selectedPage != .overview {
            refresh(page: selectedPage, model: model, management: management, auxiliary: auxiliary)
          }
        }
        let ui = WindowsUIThread.shared
        guard
          ui.start(),
          let chat = ui.chatWebView(),
          let desktopUI = ui.desktopUIWebView()
        else { return }

        // Startup path per platform contract: launch the service when the pipe
        // is not connectable, then connect and load tasks.
        Task {
          await model.startServiceAndConnect()
        }

        while ui.isRunning() {
          let commands = WindowsMainWindow.takePendingCommands()
          for command in commands {
            run(command, model: model, management: management, auxiliary: auxiliary)
          }
          if commands.contains(where: {
            if case .windowVisibilityChanged = $0 { return false }
            return true
          }) {
            model.userDidInteract()
          }
          applyDisplay(
            model: model,
            management: management,
            auxiliary: auxiliary,
            chat: chat,
            desktopUI: desktopUI
          )
          try? await Task.sleep(nanoseconds: 10_000_000)
        }
        stopActivityScheduling()
        await model.shutdown()
      }

    #endif

    static func run(
      _ command: MainWindowCommand,
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) {
      if runDesktopCommand(command, model: model, management: management, auxiliary: auxiliary) {
        return
      }
      switch command {
      case .windowVisibilityChanged(let visible):
        updateWindowVisibility(visible, model: model)
      case .selectPage(let index):
        guard let page = WindowsMainPage(rawValue: index) else { return }
        selectPage(page, model: model, management: management, auxiliary: auxiliary)
      case .refreshAll:
        refreshAll(model: model, management: management, auxiliary: auxiliary)
      case .registerProject(let name, let path):
        Task {
          await management.registerProject(name: name, path: path)
          await model.connectAndRefresh()
          await auxiliary.workspace.refreshSelected()
        }
      case .desktopCommand, .registerAgentFromDesktop:
        return
      }
    }

    static func onUI(_ action: @escaping @Sendable () -> Void) {
      DesktopPlatformHost.enqueue(action)
    }

    static func refreshCurrentPage(
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) {
      let page = selectedPage
      Task {
        if model.connectionState != .connected { await model.startServiceAndConnect() }
        guard model.connectionState == .connected else { return }
        refresh(page: page, model: model, management: management, auxiliary: auxiliary)
      }
    }

    static func refresh(
      page: WindowsMainPage,
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) {
      switch page {
      case .overview:
        Task {
          await model.refreshServiceStatus()
          await model.refreshTasks()
          await management.refresh()
        }
      case .workbench:
        Task { await model.refreshSelectedTask() }
      case .projects:
        Task { await management.refreshProjects() }
        Task { await auxiliary.workspace.refresh() }
      case .logs:
        Task { await auxiliary.logs.refresh() }
      case .connections:
        Task {
          await auxiliary.connections.refresh()
          await management.refreshAgents()
          await auxiliary.agentDefaults.refresh()
        }
      case .settings:
        Task {
          await auxiliary.settings.refresh()
          await auxiliary.agentDefaults.refresh()
        }
      }
    }

    static func refreshAll(
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) {
      Task {
        await model.connectAndRefresh()
        await management.refresh()
        await auxiliary.refreshAll()
      }
    }

  }
#endif

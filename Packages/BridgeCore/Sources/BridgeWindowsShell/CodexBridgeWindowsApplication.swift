#if os(Windows)
  import Foundation
  import WinSDK

  /// Windows desktop shell entry point. Models stay on MainActor while the
  /// thread-affine Win32 message pump lives on `WindowsUIThread`.
  @MainActor
  public enum CodexBridgeWindowsApplication {
    static var selectedPage = WindowsMainPage.overview

    public static func main() async {
      let feedback = WindowsDesktopFeedbackStore()
      let model = WindowsWorkbenchModel(feedback: feedback)
      let management = WindowsManagementModel(client: model.client, feedback: feedback)
      let auxiliary = WindowsAuxiliaryRuntime(client: model.client, feedback: feedback)
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
        await management.refresh()
        await auxiliary.refreshAll()
      }

      while ui.isRunning() {
        for command in WindowsMainWindow.takePendingCommands() {
          run(command, model: model, management: management, auxiliary: auxiliary)
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
      await model.shutdown()
    }

    private static func run(
      _ command: MainWindowCommand,
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) {
      if runDesktopCommand(command, model: model, management: management, auxiliary: auxiliary) {
        return
      }
      switch command {
      case .selectPage(let index):
        guard let page = WindowsMainPage(rawValue: index) else { return }
        selectedPage = page
        onUI { WindowsMainWindow.selectPage(page) }
        refresh(page: page, model: model, management: management, auxiliary: auxiliary)
      case .refreshAll:
        refreshAll(model: model, management: management, auxiliary: auxiliary)
      case .openTask(let id):
        model.selectTask(id: id)
        synchronizeTaskProject(model: model, management: management, auxiliary: auxiliary)
        selectedPage = .workbench
        onUI { WindowsMainWindow.selectPage(.workbench) }
      case .browserBack:
        onUI { WindowsMainWindow.chat?.goBack() }
      case .browserForward:
        onUI { WindowsMainWindow.chat?.goForward() }
      case .browserReload:
        onUI { WindowsMainWindow.chat?.reload() }
      case .openChatExternally:
        onUI { openChatExternally() }
      case .refreshTasks:
        Task { await model.refreshSelectedTask() }
      case .startService:
        Task {
          await model.startServiceAndConnect()
          await management.refresh()
        }
      case .selectTask(let index):
        model.selectTask(at: index)
        synchronizeTaskProject(model: model, management: management, auxiliary: auxiliary)
      case .selectWorkbenchProject(let index):
        management.selectProject(at: index)
        auxiliary.run(.selectWorkspaceProject(index: index))
        Task { await model.selectWorkbenchProject(at: index) }
      case .selectWorkbenchPermission(let index):
        Task { await model.selectWorkbenchPermission(at: index) }
      case .selectWorkbenchItem(let index):
        Task { await model.selectWorkbenchItem(at: index) }
      case .interruptSelectedTask:
        Task { await model.interruptSelectedTask() }
      case .stopSelectedTask:
        Task { await model.stopSelectedTask() }
      case .deleteSelectedTask:
        Task { await model.deleteSelectedTask() }
      case .submitSteer(let input):
        Task { await model.submitSteer(input: input) }
      case .selectApproval(let index):
        model.selectApproval(at: index)
      case .refreshApprovals:
        Task { await model.refreshApprovals() }
      case .resolveApproval(let decision):
        guard let approvalID = model.selectedApprovalID else { return }
        Task { await model.resolveApproval(approvalID, decision: decision) }
      case .selectProject(let index):
        management.selectProject(at: index)
        auxiliary.run(.selectWorkspaceProject(index: index))
        Task { await model.selectWorkbenchProject(at: index) }
      case .selectWorkspaceProject(let index):
        auxiliary.run(.selectWorkspaceProject(index: index))
        management.selectProject(at: index)
        Task { await model.selectWorkbenchProject(at: index) }
      case .refreshProjects:
        Task { await management.refreshProjects() }
      case .registerProject(let name, let path):
        Task {
          await management.registerProject(name: name, path: path)
          await model.connectAndRefresh()
          auxiliary.run(.refreshWorkspace)
        }
      case .removeSelectedProject:
        guard let projectID = management.selectedProjectID else { return }
        Task {
          await management.removeSelectedProject(projectID: projectID)
          await model.connectAndRefresh()
          auxiliary.run(.refreshWorkspace)
        }
      case .saveProjectPolicy(let read, let write, let network):
        guard let projectID = management.selectedProjectID else { return }
        Task {
          await management.saveSelectedProjectPolicy(
            read: read,
            write: write,
            network: network,
            projectID: projectID
          )
        }
      case .selectAgentProvider(let index):
        management.selectProvider(at: index)
      case .selectAgentInstallation(let index):
        management.selectInstallation(at: index)
      case .refreshAgents:
        Task { await management.refreshAgents() }
      case .registerAgent(let providerID, let executablePath, let configurationPath):
        Task {
          await management.registerAgent(
            providerID: providerID,
            executablePath: executablePath,
            configurationPath: configurationPath
          )
          await auxiliary.agentDefaults.refresh()
        }
      case .enableSelectedAgent:
        guard let id = management.selectedInstallationID else { return }
        Task {
          await management.setSelectedAgentEnabled(true, installationID: id)
          await auxiliary.agentDefaults.refresh()
        }
      case .disableSelectedAgent:
        guard let id = management.selectedInstallationID else { return }
        Task {
          await management.setSelectedAgentEnabled(false, installationID: id)
          await auxiliary.agentDefaults.refresh()
        }
      case .reprobeSelectedAgent(let acceptReplacement):
        guard let id = management.selectedInstallationID else { return }
        Task {
          await management.reprobeSelectedAgent(
            acceptReplacement: acceptReplacement, installationID: id)
          await auxiliary.agentDefaults.refresh()
        }
      case .removeSelectedAgent:
        guard let id = management.selectedInstallationID else { return }
        Task {
          await management.removeSelectedAgent(installationID: id)
          await auxiliary.agentDefaults.refresh()
        }
      default:
        auxiliary.run(command)
      }
    }

    static func onUI(_ action: @escaping @Sendable () -> Void) {
      WindowsUIThread.shared.enqueue(action)
    }

    private static func refresh(
      page: WindowsMainPage,
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) {
      switch page {
      case .overview:
        Task {
          await model.refreshTasks()
          await management.refresh()
        }
      case .workbench:
        Task { await model.refreshSelectedTask() }
      case .projects:
        Task { await management.refreshProjects() }
        auxiliary.run(.refreshWorkspace)
      case .logs:
        auxiliary.run(.refreshLogs)
      case .connections:
        auxiliary.run(.refreshMCPConnections)
        Task {
          await management.refreshAgents()
          await auxiliary.agentDefaults.refresh()
        }
      case .settings:
        auxiliary.run(.refreshSettings)
        auxiliary.run(.refreshAgentDefaults)
      }
    }

    private static func refreshAll(
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

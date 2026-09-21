#if os(Windows)
  import BridgeServiceAppCore
  import Foundation

  @MainActor
  final class WindowsAuxiliaryRuntime {
    let workspace: WindowsWorkspaceModel
    let agentDefaults: WindowsAgentDefaultsModel
    let logs: WindowsLogModel
    let settings: WindowsSettingsModel
    let connections: WindowsConnectionModel

    init(
      client: any BridgeServiceClientProtocol,
      feedback: WindowsDesktopFeedbackStore
    ) {
      workspace = WindowsWorkspaceModel(client: client, feedback: feedback)
      agentDefaults = WindowsAgentDefaultsModel(client: client, feedback: feedback)
      logs = WindowsLogModel(client: client, feedback: feedback)
      settings = WindowsSettingsModel(client: client, feedback: feedback)
      connections = WindowsConnectionModel(client: client, feedback: feedback)
    }

    func refreshAll() async {
      await workspace.refresh()
      await logs.refresh()
      await connections.refresh()
      await settings.refresh()
      await agentDefaults.refresh()
    }

    func run(_ command: MainWindowCommand) {
      switch command {
      case .selectWorkspaceProject, .selectWorkspaceCommand,
        .selectWorkspaceSkill, .selectWorkspaceThread, .refreshWorkspace, .setWorkspaceMode,
        .selectWorkspaceBlacklist, .saveWorkspaceCommand, .removeSelectedWorkspaceCommand,
        .saveWorkspaceBlacklist, .removeSelectedWorkspaceBlacklist:
        runWorkspace(command)
      case .selectDefaultProvider, .selectDefaultInstallation,
        .refreshAgentDefaults, .refreshAgentModels, .saveAgentDefaults:
        runAgentDefaults(command)
      case .refreshLogs, .selectLog, .setLogSearch, .setLogProjectFilter,
        .setLogKindFilter, .copyLogs:
        runLogs(command)
      case .refreshSettings, .saveSettingsPreferences, .saveDirectConfiguration,
        .saveSettingsInstructions, .setSettingsDirectApprovalMode,
        .setSettingsTaskStartApprovalMode,
        .registerService, .unregisterService, .setKeepServiceRunning:
        runSettings(command)
      case .selectMCPClient, .refreshMCPConnections, .toggleSelectedMCPClient,
        .setSelectedMCPExposure, .copySelectedMCPConfiguration,
        .copyLocalMCPEndpoint, .rotateSelectedMCPCredential, .rotateLocalMCPEndpoint:
        runConnections(command)
      default:
        break
      }
    }

    private func runConnections(_ command: MainWindowCommand) {
      switch command {
      case .selectMCPClient(let index):
        connections.selectClient(at: index)
      case .refreshMCPConnections:
        Task { await connections.refresh() }
      case .toggleSelectedMCPClient:
        guard let clientID = connections.selectedClientID else { return }
        Task { await connections.toggleSelectedClient(clientID: clientID) }
      case .setSelectedMCPExposure(let index):
        guard let clientID = connections.selectedClientID else { return }
        Task { await connections.setSelectedExposure(at: index, clientID: clientID) }
      case .copySelectedMCPConfiguration:
        guard let clientID = connections.selectedClientID else { return }
        Task {
          guard
            let configuration = await connections.exportSelectedConfiguration(clientID: clientID)
          else { return }
          connections.didCopyConfiguration(
            WindowsClipboard.write(configuration, owner: WindowsMainWindow.currentWindow()))
        }
      case .copyLocalMCPEndpoint:
        guard let endpoint = connections.localMCPEndpoint else { return }
        connections.didCopyEndpoint(
          WindowsClipboard.write(endpoint, owner: WindowsMainWindow.currentWindow()))
      case .rotateSelectedMCPCredential:
        guard let clientID = connections.selectedClientID else { return }
        Task { await connections.rotateSelectedCredential(clientID: clientID) }
      case .rotateLocalMCPEndpoint:
        Task { await connections.rotateEndpoint() }
      default:
        break
      }
    }

    private func runWorkspace(_ command: MainWindowCommand) {
      switch command {
      case .selectWorkspaceProject(let index):
        workspace.selectProject(at: index)
      case .selectWorkspaceCommand(let index):
        workspace.selectCommand(at: index)
      case .selectWorkspaceSkill(let index):
        workspace.selectSkill(at: index)
      case .selectWorkspaceThread(let index):
        workspace.selectThread(at: index)
      case .selectWorkspaceBlacklist(let index):
        workspace.selectBlacklist(at: index)
      case .refreshWorkspace:
        Task { await workspace.refreshSelected() }
      case .setWorkspaceMode(let mode):
        guard let projectID = workspace.selectedProjectID else { return }
        Task { await workspace.setMode(mode, projectID: projectID) }
      case .saveWorkspaceCommand(
        let name,
        let executable,
        let arguments,
        let workingDirectory,
        let requiresNetwork,
        let risk
      ):
        let draft = BridgeWorkspaceCommandDraft(
          name: name,
          executable: executable,
          arguments: arguments,
          workingDirectory: workingDirectory,
          requiresNetwork: requiresNetwork,
          risk: risk
        )
        guard let context = workspace.editContext else { return }
        Task { await workspace.saveCommand(draft, context: context) }
      case .removeSelectedWorkspaceCommand:
        guard let context = workspace.editContext else { return }
        Task { await workspace.removeSelectedCommand(context: context) }
      case .saveWorkspaceBlacklist(let executable, let pattern):
        guard let context = workspace.editContext else { return }
        Task {
          await workspace.saveBlacklist(executable: executable, pattern: pattern, context: context)
        }
      case .removeSelectedWorkspaceBlacklist:
        guard let context = workspace.editContext else { return }
        Task { await workspace.removeSelectedBlacklist(context: context) }
      default:
        break
      }
    }

    private func runAgentDefaults(_ command: MainWindowCommand) {
      switch command {
      case .selectDefaultProvider(let index):
        agentDefaults.selectProvider(at: index)
        Task { await agentDefaults.refreshModels(forceRefresh: false) }
      case .selectDefaultInstallation(let index):
        agentDefaults.selectInstallation(at: index)
        Task { await agentDefaults.refreshModels(forceRefresh: false) }
      case .refreshAgentDefaults:
        Task { await agentDefaults.refresh() }
      case .refreshAgentModels:
        Task { await agentDefaults.refreshModels(forceRefresh: true) }
      case .saveAgentDefaults(let model, let permissionMode, let effort):
        Task {
          await agentDefaults.saveDefaults(
            model: model, permissionMode: permissionMode, effort: effort)
        }
      default:
        break
      }
    }

    private func runLogs(_ command: MainWindowCommand) {
      switch command {
      case .refreshLogs:
        Task { await logs.refresh() }
      case .selectLog(let index):
        logs.selectItem(at: index)
      case .setLogSearch(let text):
        logs.setSearchText(text)
      case .setLogProjectFilter(let index):
        logs.setProjectFilter(index)
      case .setLogKindFilter(let index):
        logs.setKindFilter(index)
      case .copyLogs:
        let display = logs.displayBox.current()
        logs.didCopy(
          WindowsClipboard.write(display.copyText, owner: WindowsMainWindow.currentWindow()))
      default:
        break
      }
    }

    private func runSettings(_ command: MainWindowCommand) {
      switch command {
      case .refreshSettings:
        Task { await settings.refresh() }
      case .saveDirectConfiguration(let json):
        Task { await settings.saveDirectConfiguration(json) }
      case .saveSettingsPreferences(let preferences):
        Task { await settings.savePreferences(preferences) }
      case .saveSettingsInstructions(let text):
        Task { await settings.saveInstructions(text) }
      case .setSettingsDirectApprovalMode(let mode):
        Task { await settings.setDirectApprovalMode(mode) }
      case .setSettingsTaskStartApprovalMode(let mode):
        Task { await settings.setTaskStartApprovalMode(mode) }
      case .registerService:
        Task { await settings.registerService() }
      case .unregisterService:
        Task { await settings.unregisterService() }
      case .setKeepServiceRunning(let keep):
        settings.setKeepServiceRunningAfterExit(keep)
      default:
        break
      }
    }
  }
#endif

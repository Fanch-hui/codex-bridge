#if os(Windows)
  import BridgeServiceAppCore

  extension CodexBridgeWindowsApplication {
    static func runDesktopProjectCommand(
      _ command: MainWindowCommand,
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) -> Bool {
      switch command {
      case .selectProjectByID(let projectID):
        guard let index = management.projects.firstIndex(where: { $0.projectID == projectID })
        else {
          return true
        }
        management.selectProject(at: index)
        auxiliary.workspace.selectProject(id: projectID)
        auxiliary.agentDefaults.workbenchProjectID = projectID
        Task { @MainActor in
          await model.selectWorkbenchProject(id: projectID)
          await auxiliary.agentDefaults.refreshAllProviderModels()
        }
      case .beginProjectRegistration:
        WindowsDesktopUIHostActions.chooseProjectDirectory { name, path in
          WindowsMainWindow.enqueue(.registerProject(name: name, path: path))
        }
      case .removeProject(let projectID):
        guard management.selectedProjectID == projectID else { return true }
        Task { @MainActor in
          await management.removeSelectedProject(projectID: projectID)
          await model.connectAndRefresh()
          auxiliary.run(.refreshWorkspace)
        }
      case .saveProjectPolicyByID(let projectID, let read, let write, let network):
        guard management.selectedProjectID == projectID else { return true }
        Task { @MainActor in
          await management.saveSelectedProjectPolicy(
            read: read, write: write, network: network, projectID: projectID)
        }
      case .setProjectCommandMode(let projectID, let mode):
        guard auxiliary.workspace.selectedProjectID == projectID else { return true }
        Task { @MainActor in await auxiliary.workspace.setMode(mode, projectID: projectID) }
      case .saveProjectCommand(
        let projectID,
        let commandID,
        let name,
        let executable,
        let arguments,
        let workingDirectory,
        let requiresNetwork,
        let risk
      ):
        guard auxiliary.workspace.selectedProjectID == projectID else { return true }
        guard
          commandID == nil || auxiliary.workspace.commands.contains(where: { $0.id == commandID })
        else { return true }
        guard var context = auxiliary.workspace.editContext else { return true }
        context.commandID = commandID
        let draft = BridgeWorkspaceCommandDraft(
          name: name,
          executable: executable,
          arguments: arguments.joined(separator: "\n"),
          workingDirectory: workingDirectory ?? "",
          requiresNetwork: requiresNetwork,
          risk: risk
        )
        Task { @MainActor in await auxiliary.workspace.saveCommand(draft, context: context) }
      case .removeProjectCommand(let projectID, let commandID):
        guard auxiliary.workspace.selectedProjectID == projectID,
          auxiliary.workspace.commands.contains(where: { $0.id == commandID })
        else { return true }
        guard var context = auxiliary.workspace.editContext else { return true }
        context.commandID = commandID
        Task { @MainActor in await auxiliary.workspace.removeSelectedCommand(context: context) }
      case .saveProjectBlacklist(let projectID, let ruleID, let executable, let pattern):
        guard auxiliary.workspace.selectedProjectID == projectID else { return true }
        guard ruleID == nil || auxiliary.workspace.blacklists.contains(where: { $0.id == ruleID })
        else { return true }
        guard var context = auxiliary.workspace.editContext else { return true }
        context.blacklistID = ruleID
        Task { @MainActor in
          await auxiliary.workspace.saveBlacklist(
            executable: executable ?? "",
            pattern: pattern ?? "",
            context: context
          )
        }
      case .removeProjectBlacklist(let projectID, let ruleID):
        guard auxiliary.workspace.selectedProjectID == projectID,
          auxiliary.workspace.blacklists.contains(where: { $0.id == ruleID })
        else { return true }
        guard var context = auxiliary.workspace.editContext else { return true }
        context.blacklistID = ruleID
        Task { @MainActor in await auxiliary.workspace.removeSelectedBlacklist(context: context) }
      case .openThread(let projectID, let threadID):
        let isWorkbenchThread =
          model.selectedProjectID == projectID
          && model.threads.contains(where: { $0.threadID == threadID })
        let isProjectThread =
          auxiliary.workspace.selectedProjectID == projectID
          && auxiliary.workspace.threads.contains(where: { $0.threadID == threadID })
        guard isWorkbenchThread || isProjectThread else { return true }
        selectedPage = .workbench
        onUI { WindowsMainWindow.selectPage(.workbench) }
        Task { @MainActor in
          await model.openWorkbenchThread(threadID: threadID, projectID: projectID)
          synchronizeTaskProject(model: model, management: management, auxiliary: auxiliary)
        }
      default:
        return false
      }
      return true
    }
  }
#endif

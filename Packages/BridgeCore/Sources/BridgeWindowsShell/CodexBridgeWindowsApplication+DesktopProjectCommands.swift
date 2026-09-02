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
        auxiliary.workspace.selectProject(at: index)
        Task { @MainActor in await model.selectWorkbenchProject(at: index) }
      case .beginProjectRegistration:
        WindowsDesktopUIHostActions.chooseProjectDirectory { name, path in
          WindowsMainWindow.enqueue(.registerProject(name: name, path: path))
        }
      case .removeProject(let projectID):
        guard management.selectedProjectID == projectID else { return true }
        Task { @MainActor in
          await management.removeSelectedProject()
          await model.connectAndRefresh()
          auxiliary.run(.refreshWorkspace)
        }
      case .saveProjectPolicyByID(let projectID, let read, let write, let network):
        guard management.selectedProjectID == projectID else { return true }
        Task { @MainActor in
          await management.saveSelectedProjectPolicy(read: read, write: write, network: network)
        }
      case .setProjectCommandMode(let projectID, let mode):
        guard auxiliary.workspace.selectedProjectID == projectID else { return true }
        Task { @MainActor in await auxiliary.workspace.setMode(mode) }
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
        auxiliary.workspace.selectedCommandID = commandID
        let draft = BridgeWorkspaceCommandDraft(
          name: name,
          executable: executable,
          arguments: arguments.joined(separator: "\n"),
          workingDirectory: workingDirectory ?? "",
          requiresNetwork: requiresNetwork,
          risk: risk
        )
        Task { @MainActor in await auxiliary.workspace.saveCommand(draft) }
      case .removeProjectCommand(let projectID, let commandID):
        guard auxiliary.workspace.selectedProjectID == projectID,
          auxiliary.workspace.commands.contains(where: { $0.id == commandID })
        else { return true }
        auxiliary.workspace.selectedCommandID = commandID
        Task { @MainActor in await auxiliary.workspace.removeSelectedCommand() }
      case .saveProjectBlacklist(let projectID, let ruleID, let executable, let pattern):
        guard auxiliary.workspace.selectedProjectID == projectID else { return true }
        guard ruleID == nil || auxiliary.workspace.blacklists.contains(where: { $0.id == ruleID })
        else { return true }
        auxiliary.workspace.selectedBlacklistID = ruleID
        Task { @MainActor in
          await auxiliary.workspace.saveBlacklist(
            executable: executable ?? "",
            pattern: pattern ?? ""
          )
        }
      case .removeProjectBlacklist(let projectID, let ruleID):
        guard auxiliary.workspace.selectedProjectID == projectID,
          auxiliary.workspace.blacklists.contains(where: { $0.id == ruleID })
        else { return true }
        auxiliary.workspace.selectedBlacklistID = ruleID
        Task { @MainActor in await auxiliary.workspace.removeSelectedBlacklist() }
      case .openThread(let projectID, let threadID):
        guard auxiliary.workspace.selectedProjectID == projectID,
          let index = auxiliary.workspace.threads.firstIndex(where: { $0.threadID == threadID })
        else { return true }
        auxiliary.workspace.selectThread(at: index)
      default:
        return false
      }
      return true
    }
  }
#endif

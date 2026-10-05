#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import BridgeServiceAppCore

  extension CodexBridgeDesktopApplication {
    static func runDesktopProjectCommand(
      _ envelope: BridgeDesktopCommandEnvelope,
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) -> Bool {
      let payload = envelope.payload
      switch envelope.command {
      case .selectProject:
        guard let projectID = BridgeDesktopCommandValue.nonEmpty(payload.projectID),
          let index = management.projects.firstIndex(where: { $0.projectID == projectID })
        else { return true }
        management.selectProject(at: index)
        auxiliary.workspace.selectProject(id: projectID)
        auxiliary.agentDefaults.workbenchProjectID = projectID
        Task { @MainActor in
          await model.selectWorkbenchProject(id: projectID)
          await auxiliary.agentDefaults.refreshAllProviderModels()
        }
      case .refreshProjects:
        Task { @MainActor in await management.refreshProjects() }
      case .registerProject:
        guard let name = BridgeDesktopCommandValue.nonEmpty(payload.name),
          let path = BridgeDesktopCommandValue.nonEmpty(payload.path)
        else {
          DesktopPlatformHost.chooseProjectDirectory { name, path in
            DesktopPlatformHost.enqueueCommand(.registerProject(name: name, path: path))
          }
          return true
        }
        Task { @MainActor in
          await management.registerProject(name: name, path: path)
          await model.connectAndRefresh()
          await auxiliary.workspace.refreshSelected()
        }
      case .removeProject:
        guard let projectID = BridgeDesktopCommandValue.nonEmpty(payload.projectID),
          management.selectedProjectID == projectID
        else { return true }
        Task { @MainActor in
          await management.removeSelectedProject(projectID: projectID)
          await model.connectAndRefresh()
          await auxiliary.workspace.refreshSelected()
        }
      case .setProjectCommandMode:
        guard let projectID = BridgeDesktopCommandValue.nonEmpty(payload.projectID),
          let mode = BridgeDesktopCommandValue.nonEmpty(payload.mode),
          auxiliary.workspace.selectedProjectID == projectID
        else { return true }
        Task { @MainActor in await auxiliary.workspace.setMode(mode, projectID: projectID) }
      case .saveProjectCommand:
        return saveCommand(payload, auxiliary: auxiliary)
      case .removeProjectCommand:
        return removeCommand(payload, auxiliary: auxiliary)
      case .saveProjectBlacklist:
        return saveBlacklist(payload, auxiliary: auxiliary)
      case .removeProjectBlacklist:
        return removeBlacklist(payload, auxiliary: auxiliary)
      case .openThread:
        return openThread(payload, model: model, management: management, auxiliary: auxiliary)
      default:
        return false
      }
      return true
    }

    private static func saveCommand(
      _ payload: BridgeDesktopCommandPayload,
      auxiliary: WindowsAuxiliaryRuntime
    ) -> Bool {
      guard let projectID = BridgeDesktopCommandValue.nonEmpty(payload.projectID),
        let name = payload.name,
        let executable = payload.executable,
        BridgeDesktopCommandValue.nonEmpty(name, maximumUTF8Bytes: 256) != nil,
        BridgeDesktopCommandValue.nonBlankText(executable, maximumUTF8Bytes: 4_096) != nil,
        auxiliary.workspace.selectedProjectID == projectID,
        let arguments = BridgeDesktopCommandValue.arguments(
          payload.arguments ?? [],
          maximumCount: 128,
          maximumUTF8BytesPerArgument: 4_096
        ),
        let risk = BridgeDesktopCommandValue.nonEmpty(
          payload.risk ?? "normal",
          maximumUTF8Bytes: 64
        )
      else { return true }
      let commandID = BridgeDesktopCommandValue.nonEmpty(payload.commandID)
      guard
        commandID == nil
          || BridgeDesktopCommandValue.nonEmpty(payload.commandID, maximumUTF8Bytes: 256) != nil,
        payload.workingDirectory == nil
          || BridgeDesktopCommandValue.pathText(
            payload.workingDirectory,
            maximumUTF8Bytes: BridgeDesktopCommandValue.maximumPathBytes
          ) != nil,
        let context = commandContext(
          projectID: projectID,
          commandID: commandID,
          auxiliary: auxiliary
        )
      else { return true }
      let draft = BridgeWorkspaceCommandDraft(
        name: name,
        executable: executable,
        arguments: arguments.joined(separator: "\n"),
        workingDirectory: BridgeDesktopCommandValue.nonEmpty(payload.workingDirectory) ?? "",
        requiresNetwork: payload.requiresNetwork ?? false,
        risk: risk
      )
      Task { @MainActor in await auxiliary.workspace.saveCommand(draft, context: context) }
      return true
    }

    private static func removeCommand(
      _ payload: BridgeDesktopCommandPayload,
      auxiliary: WindowsAuxiliaryRuntime
    ) -> Bool {
      guard let projectID = BridgeDesktopCommandValue.nonEmpty(payload.projectID),
        let commandID = BridgeDesktopCommandValue.nonEmpty(payload.commandID),
        auxiliary.workspace.selectedProjectID == projectID,
        auxiliary.workspace.commands.contains(where: { $0.id == commandID }),
        let context = commandContext(
          projectID: projectID, commandID: commandID, auxiliary: auxiliary)
      else { return true }
      Task { @MainActor in await auxiliary.workspace.removeSelectedCommand(context: context) }
      return true
    }

    private static func saveBlacklist(
      _ payload: BridgeDesktopCommandPayload,
      auxiliary: WindowsAuxiliaryRuntime
    ) -> Bool {
      guard let projectID = BridgeDesktopCommandValue.nonEmpty(payload.projectID),
        auxiliary.workspace.selectedProjectID == projectID
      else { return true }
      let ruleID = BridgeDesktopCommandValue.nonEmpty(payload.ruleID)
      guard ruleID == nil || auxiliary.workspace.blacklists.contains(where: { $0.id == ruleID }),
        var context = auxiliary.workspace.editContext
      else { return true }
      context.blacklistID = ruleID
      let executable = BridgeDesktopCommandValue.nonEmpty(payload.executable) ?? ""
      let pattern = BridgeDesktopCommandValue.nonEmpty(payload.pattern) ?? ""
      Task { @MainActor in
        await auxiliary.workspace.saveBlacklist(
          executable: executable,
          pattern: pattern,
          context: context
        )
      }
      return true
    }

    private static func removeBlacklist(
      _ payload: BridgeDesktopCommandPayload,
      auxiliary: WindowsAuxiliaryRuntime
    ) -> Bool {
      guard let projectID = BridgeDesktopCommandValue.nonEmpty(payload.projectID),
        let ruleID = BridgeDesktopCommandValue.nonEmpty(payload.ruleID),
        auxiliary.workspace.selectedProjectID == projectID,
        auxiliary.workspace.blacklists.contains(where: { $0.id == ruleID }),
        var context = auxiliary.workspace.editContext
      else { return true }
      context.blacklistID = ruleID
      Task { @MainActor in await auxiliary.workspace.removeSelectedBlacklist(context: context) }
      return true
    }

    private static func commandContext(
      projectID: String,
      commandID: String?,
      auxiliary: WindowsAuxiliaryRuntime
    ) -> WindowsWorkspaceEditContext? {
      guard
        commandID == nil || auxiliary.workspace.commands.contains(where: { $0.id == commandID }),
        var context = auxiliary.workspace.editContext,
        context.projectID == projectID
      else { return nil }
      context.commandID = commandID
      return context
    }

    private static func openThread(
      _ payload: BridgeDesktopCommandPayload,
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) -> Bool {
      guard let projectID = BridgeDesktopCommandValue.nonEmpty(payload.projectID),
        let threadID = BridgeDesktopCommandValue.nonEmpty(payload.threadID)
      else { return true }
      let isWorkbenchThread =
        model.selectedProjectID == projectID
        && model.threads.contains(where: { $0.threadID == threadID })
      let isProjectThread =
        auxiliary.workspace.selectedProjectID == projectID
        && auxiliary.workspace.threads.contains(where: { $0.threadID == threadID })
      guard isWorkbenchThread || isProjectThread else { return true }
      selectedPage = .workbench
      onUI { DesktopPlatformHost.selectPage(.workbench) }
      Task { @MainActor in
        await model.openWorkbenchThread(threadID: threadID, projectID: projectID)
        synchronizeTaskProject(model: model, management: management, auxiliary: auxiliary)
      }
      return true
    }
  }
#endif

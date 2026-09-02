#if os(Windows)
  import BridgeIPC
  import BridgeServiceAppCore

  extension CodexBridgeWindowsApplication {
    static func runDesktopCommand(
      _ command: MainWindowCommand,
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) -> Bool {
      switch command {
      case .setBrowserEnabled:
        return true
      case .loadEarlierConversation(let taskID):
        guard model.selectedTaskID == taskID else { return true }
        Task { @MainActor in
          await model.conversation?.loadEarlier()
          model.refreshDisplaySnapshot()
        }
        return true
      case .refreshConversation(let taskID):
        guard model.selectedTaskID == taskID else { return true }
        Task { @MainActor in
          await model.conversation?.reloadAuthoritativeSnapshot()
          model.refreshDisplaySnapshot()
        }
        return true
      case .setWorkbenchPermissionMode(let mode):
        guard let index = ["read-only", "workspace-write"].firstIndex(of: mode) else {
          return true
        }
        Task { @MainActor in await model.selectWorkbenchPermission(at: index) }
        return true
      case .selectTask(id: let taskID):
        model.selectTask(id: taskID)
        return true
      case .interruptTask(let taskID):
        guard model.selectedTaskID == taskID else { return true }
        Task { @MainActor in await model.interruptSelectedTask() }
        return true
      case .stopTask(let taskID):
        guard model.selectedTaskID == taskID else { return true }
        Task { @MainActor in await model.stopSelectedTask() }
        return true
      case .deleteTask(let taskID):
        guard model.selectedTaskID == taskID else { return true }
        Task { @MainActor in await model.deleteSelectedTask() }
        return true
      case .steerTask(let taskID, let input, let mode):
        guard model.selectedTaskID == taskID, mode == "queued" else { return true }
        Task { @MainActor in _ = await model.submitSteer(input: input) }
        return true
      case .resolveTaskApproval(let approvalID, let taskID, let decision):
        return resolveTaskApproval(
          approvalID: approvalID,
          taskID: taskID,
          decision: decision,
          model: model
        )
      case .resolveDirectApproval(let approvalID, let decision):
        return resolveDirectApproval(
          approvalID: approvalID,
          decision: decision,
          model: model
        )
      case .selectProject, .beginProjectRegistration, .removeProject, .saveProjectPolicy,
        .setProjectCommandMode, .saveProjectCommand, .removeProjectCommand,
        .saveProjectBlacklist, .removeProjectBlacklist, .openThread:
        return runDesktopProjectCommand(
          command,
          model: model,
          management: management,
          auxiliary: auxiliary
        )
      case .selectLog(let id, _):
        guard
          let index = auxiliary.logs.displayBox.current().rowsTyped.firstIndex(where: {
            $0.id == id
          })
        else { return true }
        auxiliary.logs.selectItem(at: index)
        return true
      case .setLogProjectFilter(let projectID):
        let display = auxiliary.logs.displayBox.current()
        let target = projectID ?? "all"
        guard let index = display.projectOptions.firstIndex(where: { $0.id == target }) else {
          return true
        }
        auxiliary.logs.setProjectFilter(index)
        return true
      case .setLogKindFilter(let kind):
        guard let index = ["all", "command", "file", "error", "event"].firstIndex(of: kind) else {
          return true
        }
        auxiliary.logs.setKindFilter(index)
        return true
      case .setMCPClientEnabled(let id, let enabled):
        guard let index = auxiliary.connections.clients.firstIndex(where: { $0.clientID == id })
        else {
          return true
        }
        auxiliary.connections.selectClient(at: index)
        guard auxiliary.connections.clients[index].enabled != enabled else { return true }
        Task { @MainActor in await auxiliary.connections.toggleSelectedClient() }
        return true
      case .setMCPClientExposure(let id, let exposureMode):
        guard
          let clientIndex = auxiliary.connections.clients.firstIndex(where: { $0.clientID == id }),
          let modeIndex = ["read-only", "full"].firstIndex(of: exposureMode)
        else { return true }
        auxiliary.connections.selectClient(at: clientIndex)
        Task { @MainActor in await auxiliary.connections.setSelectedExposure(at: modeIndex) }
        return true
      case .copyMCPClientConfiguration(let id):
        guard let index = auxiliary.connections.clients.firstIndex(where: { $0.clientID == id })
        else {
          return true
        }
        auxiliary.connections.selectClient(at: index)
        auxiliary.run(.copySelectedMCPConfiguration)
        return true
      case .rotateMCPClientCredential(let id):
        guard let index = auxiliary.connections.clients.firstIndex(where: { $0.clientID == id })
        else {
          return true
        }
        auxiliary.connections.selectClient(at: index)
        Task { @MainActor in await auxiliary.connections.rotateSelectedCredential() }
        return true
      case .selectAgent(let id):
        if let index = management.agentInstallations.firstIndex(where: { $0.installationID == id })
        {
          management.selectInstallation(at: index)
        } else if let index = management.agentProviders.firstIndex(where: { $0.providerID == id }) {
          management.selectProvider(at: index)
        }
        return true
      case .setAgentEnabled(let id, let enabled):
        guard
          let index = management.agentInstallations.firstIndex(where: { $0.installationID == id })
        else {
          return true
        }
        management.selectInstallation(at: index)
        Task { @MainActor in await management.setSelectedAgentEnabled(enabled) }
        return true
      case .reprobeAgent(let id, let acceptReplacement):
        guard
          let index = management.agentInstallations.firstIndex(where: { $0.installationID == id })
        else {
          return true
        }
        management.selectInstallation(at: index)
        Task { @MainActor in
          await management.reprobeSelectedAgent(acceptReplacement: acceptReplacement)
        }
        return true
      case .removeAgent(let id):
        guard
          let index = management.agentInstallations.firstIndex(where: { $0.installationID == id })
        else {
          return true
        }
        management.selectInstallation(at: index)
        Task { @MainActor in await management.removeSelectedAgent() }
        return true
      case .registerAgentFromDesktop(
        let providerID, let displayName, let executablePath, let configurationPath):
        Task { @MainActor in
          await management.registerAgent(
            providerID: providerID,
            executablePath: executablePath,
            configurationPath: configurationPath ?? ""
          )
        }
        return true
      case .refreshAgentModels(let providerID, let installationID):
        guard auxiliary.agentDefaults.selectedProviderID == providerID,
          auxiliary.agentDefaults.selectedInstallationID == installationID
        else { return true }
        Task { @MainActor in await auxiliary.agentDefaults.refreshModels() }
        return true
      case .saveAgentDefault(
        let providerID, let installationID, let modelID, let permissionMode, let effort):
        guard auxiliary.agentDefaults.selectedProviderID == providerID,
          auxiliary.agentDefaults.selectedInstallationID == installationID
        else { return true }
        Task { @MainActor in
          await auxiliary.agentDefaults.saveDefaults(
            model: modelID,
            permissionMode: permissionMode,
            effort: effort ?? ""
          )
        }
        return true
      case .saveSettingsExecutionPreferences(
        let executionModel,
        let executionEffort,
        let accessMode,
        let fastModeEnabled
      ):
        guard let current = auxiliary.settings.preferences else { return true }
        let next = IPCModelPreferences(
          executionModel: executionModel,
          executionEffort: executionEffort,
          supervisorModel: current.supervisorModel,
          supervisorEffort: current.supervisorEffort,
          supervisorEnabled: false,
          accessMode: accessMode,
          fastModeEnabled: fastModeEnabled
        )
        Task { @MainActor in await auxiliary.settings.savePreferences(next) }
        return true
      case .updateBrowserViewport(let viewport):
        WindowsMainWindow.applyBrowserViewport(viewport)
        return true
      default:
        return false
      }
    }

    private static func resolveTaskApproval(
      approvalID: String,
      taskID: String,
      decision: String,
      model: WindowsWorkbenchModel
    ) -> Bool {
      guard
        let index = model.approvalPresentationItems().firstIndex(where: { item in
          item.id == .task(approvalID)
        }), model.approvals.contains(where: { $0.approvalID == approvalID && $0.taskID == taskID })
      else { return true }
      model.selectApproval(at: index)
      Task { @MainActor in await model.resolveSelectedApproval(decision: decision) }
      return true
    }

    private static func resolveDirectApproval(
      approvalID: String,
      decision: String,
      model: WindowsWorkbenchModel
    ) -> Bool {
      guard
        let index = model.approvalPresentationItems().firstIndex(where: { item in
          item.id == .direct(approvalID)
        })
      else { return true }
      model.selectApproval(at: index)
      Task { @MainActor in await model.resolveSelectedApproval(decision: decision) }
      return true
    }

  }
#endif

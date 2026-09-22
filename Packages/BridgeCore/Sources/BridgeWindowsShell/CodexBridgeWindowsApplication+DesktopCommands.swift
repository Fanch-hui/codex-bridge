#if os(Windows)
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore
  import Foundation

  extension CodexBridgeWindowsApplication {
    static func runDesktopCommand(
      _ command: MainWindowCommand,
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) -> Bool {
      switch command {
      case .setBrowserEnabled(let enabled):
        model.setChatBrowserEnabled(enabled)
        updateBrowserMemoryPolicy(model: model)
        return true
      case .scanAgents:
        Task { @MainActor in await management.refreshAgents(forceRefresh: true) }
        return true
      case .refreshModels:
        Task { @MainActor in await auxiliary.refreshModels(model: model) }
        return true
      case .setCodexExecutablePath(let path):
        Task { @MainActor in
          await auxiliary.connections.setCodexExecutablePath(path)
          await auxiliary.refreshModels(model: model)
        }
        return true
      case .loadEarlierConversation(let taskID):
        guard model.selectedTaskID == taskID,
          let conversation = model.conversation,
          conversation.taskID == taskID
        else { return true }
        Task { @MainActor in
          await conversation.loadEarlier()
          guard model.selectedTaskID == taskID, model.conversation === conversation else { return }
          model.refreshDisplaySnapshot()
        }
        return true
      case .refreshConversation(let taskID):
        guard model.selectedTaskID == taskID, let task = model.selectedTask else { return true }
        model.openConversation(for: task)
        model.refreshDisplaySnapshot()
        return true
      case .setWorkbenchPermissionMode(let mode):
        guard let index = ["read-only", "workspace-write"].firstIndex(of: mode) else {
          return true
        }
        Task { @MainActor in await model.selectWorkbenchPermission(at: index) }
        return true
      case .selectTaskByID(id: let taskID):
        model.selectTask(id: taskID)
        synchronizeTaskProject(model: model, management: management, auxiliary: auxiliary)
        selectedPage = .workbench
        onUI { WindowsMainWindow.selectPage(.workbench) }
        return true
      case .interruptTask(let taskID):
        Task { @MainActor in await model.interruptTask(id: taskID) }
        return true
      case .stopTask(let taskID):
        Task { @MainActor in await model.stopTask(id: taskID) }
        return true
      case .deleteTask(let taskID):
        Task { @MainActor in await model.deleteTask(id: taskID) }
        return true
      case .deleteSession(let taskID):
        Task { @MainActor in await model.deleteSession(containingTaskID: taskID) }
        return true
      case .steerTask(let taskID, let input, let mode, let requestID):
        guard let steerMode = MCPTaskSteerMode(rawValue: mode) else { return true }
        Task { @MainActor in
          _ = await model.submitSteer(
            taskID: taskID, input: input, mode: steerMode, requestID: requestID
          )
        }
        return true
      case .resumeTask(let taskID, let input, let requestID, let queueIfBusy):
        Task { @MainActor in
          await model.resumeTask(
            id: taskID, input: input, requestID: requestID, queueIfBusy: queueIfBusy)
        }
        return true
      case .handoffTask(let taskID, let providerID, let prompt, let requestID):
        Task { @MainActor in
          await model.handoffTask(
            id: taskID, providerID: providerID, prompt: prompt, requestID: requestID)
        }
        return true
      case .restartTask(let taskID, let requestID, let queueIfBusy):
        Task { @MainActor in
          await model.restartTask(id: taskID, requestID: requestID, queueIfBusy: queueIfBusy)
        }
        return true
      case .rejectWorkbenchCommand(let requestID, let command, let taskID, let input):
        model.rejectWorkbenchCommand(
          requestID: requestID,
          command: command,
          taskID: taskID,
          input: input,
          message: "工作台命令无法执行。"
        )
        return true
      case .resolveTaskApproval(
        let approvalID,
        let taskID,
        let decision,
        let oneTimeToolAutoApproval,
        let answersJSON):
        return resolveTaskApproval(
          approvalID: approvalID,
          taskID: taskID,
          decision: decision,
          oneTimeToolAutoApproval: oneTimeToolAutoApproval,
          answersJSON: answersJSON,
          model: model
        )
      case .resolveDirectApproval(let approvalID, let decision):
        return resolveDirectApproval(
          approvalID: approvalID,
          decision: decision,
          model: model
        )
      case .selectProjectByID, .beginProjectRegistration, .removeProject, .saveProjectPolicyByID,
        .setProjectCommandMode, .saveProjectCommand, .removeProjectCommand,
        .saveProjectBlacklist, .removeProjectBlacklist, .openThread:
        return runDesktopProjectCommand(
          command,
          model: model,
          management: management,
          auxiliary: auxiliary
        )
      case .selectLogByID(let id, let taskID):
        guard
          let index = auxiliary.logs.displayBox.current().rowsTyped.firstIndex(where: {
            $0.id == id && (taskID == nil || $0.taskID == taskID)
          })
        else { return true }
        auxiliary.logs.selectItem(at: index)
        return true
      case .setLogProjectFilterByID(let projectID):
        let display = auxiliary.logs.displayBox.current()
        let target = projectID ?? "all"
        guard let index = display.projectOptions.firstIndex(where: { $0.id == target }) else {
          return true
        }
        auxiliary.logs.setProjectFilter(index)
        return true
      case .setLogKindFilterByID(let kind):
        guard let index = ["all", "command", "file", "other"].firstIndex(of: kind) else {
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
        Task { @MainActor in await auxiliary.connections.toggleSelectedClient(clientID: id) }
        return true
      case .setMCPClientExposure(let id, let exposureMode):
        guard
          let clientIndex = auxiliary.connections.clients.firstIndex(where: { $0.clientID == id }),
          let modeIndex = ["read-only", "full"].firstIndex(of: exposureMode)
        else { return true }
        auxiliary.connections.selectClient(at: clientIndex)
        Task { @MainActor in
          await auxiliary.connections.setSelectedExposure(at: modeIndex, clientID: id)
        }
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
        Task { @MainActor in await auxiliary.connections.rotateSelectedCredential(clientID: id) }
        return true
      case .saveDeepSeekHarnessMCPServer(let request):
        Task { @MainActor in await auxiliary.connections.saveDeepSeekHarnessMCPServer(request) }
        return true
      case .deleteDeepSeekHarnessMCPServer(let id):
        Task { @MainActor in await auxiliary.connections.deleteDeepSeekHarnessMCPServer(id: id) }
        return true
      case .setDeepSeekHarnessMCPServerEnabled(let id, let enabled):
        Task {
          @MainActor in
          await auxiliary.connections.setDeepSeekHarnessMCPServerEnabled(id: id, enabled: enabled)
        }
        return true
      case .configureTunnel, .connectTunnel, .disconnectTunnel, .clearTunnel:
        return runTunnelCommand(command, connections: auxiliary.connections)
      case .selectAgent(let id):
        if let index = management.agentInstallations.firstIndex(where: { $0.installationID == id })
        {
          management.selectInstallation(at: index)
        } else if let index = management.agentProviders.firstIndex(where: { $0.providerID == id }) {
          management.selectProvider(at: index)
        }
        return true
      case .connectAgentFromDesktop(
        let providerID,
        let baseURL,
        let apiKey,
        let alwaysProceedConfirmed
      ):
        Task { @MainActor in
          await management.connectAgent(
            providerID: providerID,
            baseURL: baseURL,
            apiKey: apiKey,
            alwaysProceedConfirmed: alwaysProceedConfirmed
          )
          await auxiliary.agentDefaults.refresh()
        }
        return true
      case .setAgentEnabled(let id, let enabled):
        guard
          let index = management.agentInstallations.firstIndex(where: { $0.installationID == id })
        else {
          return true
        }
        management.selectInstallation(at: index)
        Task { @MainActor in
          await management.setSelectedAgentEnabled(enabled, installationID: id)
          await auxiliary.agentDefaults.refresh()
        }
        return true
      case .reprobeAgent(let id, let acceptReplacement):
        guard
          let index = management.agentInstallations.firstIndex(where: { $0.installationID == id })
        else {
          return true
        }
        management.selectInstallation(at: index)
        Task { @MainActor in
          await management.reprobeSelectedAgent(
            acceptReplacement: acceptReplacement, installationID: id)
          await auxiliary.agentDefaults.refresh()
        }
        return true
      case .removeAgent(let id):
        guard
          let index = management.agentInstallations.firstIndex(where: { $0.installationID == id })
        else {
          return true
        }
        management.selectInstallation(at: index)
        Task { @MainActor in
          await management.removeSelectedAgent(installationID: id)
          await auxiliary.agentDefaults.refresh()
        }
        return true
      case .beginAgentRegistration(let providerID):
        let targetProvider: IPCAgentProviderSummary? = {
          if let providerID {
            return management.agentProviders.first(where: { $0.providerID == providerID })
          }
          return management.agentProviders.first
        }()
        guard let provider = targetProvider else { return true }
        let dialogTitle: String = {
          if provider.providerID == "opencode" {
            return "选择 OpenCode 命令行工具 (opencode.cmd 或 opencode.exe)"
          }
          return "选择 \(provider.displayName) 命令行可执行文件"
        }()
        WindowsDesktopUIHostActions.chooseExecutableFile(
          title: dialogTitle
        ) { executablePath in
          if provider.requiresConfiguration {
            WindowsDesktopUIHostActions.chooseConfigFile(
              title: "选择 \(provider.displayName) 配置文件 (cordis.yml)"
            ) { configPath in
              WindowsMainWindow.enqueue(
                .registerAgentFromDesktop(
                  providerID: provider.providerID,
                  displayName: provider.displayName,
                  executablePath: executablePath,
                  configurationPath: configPath
                )
              )
            }
          } else {
            WindowsMainWindow.enqueue(
              .registerAgentFromDesktop(
                providerID: provider.providerID,
                displayName: provider.displayName,
                executablePath: executablePath,
                configurationPath: nil
              )
            )
          }
        }
        return true
      case .registerAgentFromDesktop(
        let providerID, let displayName, let executablePath, let configurationPath):
        Task { @MainActor in
          await management.registerAgent(
            providerID: providerID,
            executablePath: executablePath,
            configurationPath: configurationPath ?? "",
            displayName: displayName
          )
          await auxiliary.agentDefaults.refresh()
        }
        return true
      case .refreshAgentModelsByID(let providerID, let installationID):
        Task { @MainActor in
          await auxiliary.agentDefaults.refreshModels(
            providerID: providerID,
            installationID: installationID,
            forceRefresh: true
          )
        }
        return true
      case .saveAgentDefault(
        let providerID, let installationID, let modelID, let permissionMode, let effort):
        Task { @MainActor in
          await auxiliary.agentDefaults.saveDefaults(
            providerID: providerID,
            installationID: installationID,
            model: modelID,
            permissionMode: permissionMode,
            effort: effort ?? ""
          )
        }
        return true
      case .refreshAgentNativePermission, .setAgentNativePermissionMode,
        .addAgentNativePermissionRule, .replaceAgentNativePermissionRule,
        .removeAgentNativePermissionRule, .prepareAgentPermissionRemediation,
        .applyAgentPermissionRemediation:
        return runNativePermissionCommand(
          command,
          model: model,
          agentDefaults: auxiliary.agentDefaults
        )
      case .patchSettings(let patch):
        Task { @MainActor in await auxiliary.settings.applyPreferencesPatch(patch) }
        return true
      case .registerService:
        Task { @MainActor in await auxiliary.settings.registerService() }
        return true
      case .unregisterService:
        Task { @MainActor in await auxiliary.settings.unregisterService() }
        return true
      case .setKeepServiceRunning(let keep):
        auxiliary.settings.setKeepServiceRunningAfterExit(keep)
        return true
      case .dismissFeedback(let id):
        model.feedback.dismiss(id: id)
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
      oneTimeToolAutoApproval: Bool,
      answersJSON: String?,
      model: WindowsWorkbenchModel
    ) -> Bool {
      guard
        let index = model.approvalPresentationItems().firstIndex(where: { item in
          item.id == .task(approvalID)
        }), model.approvals.contains(where: { $0.approvalID == approvalID && $0.taskID == taskID })
      else { return true }
      let requiresAnswers =
        model.approvals.first { $0.approvalID == approvalID }?.kind == "user_input"
      let answers = decodeAnswers(answersJSON)
      guard !requiresAnswers || answers != nil else { return true }
      model.selectApproval(at: index)
      Task { @MainActor in
        await model.resolveApproval(
          .task(approvalID),
          decision: decision,
          oneTimeToolAutoApproval: oneTimeToolAutoApproval,
          answers: answers
        )
      }
      return true
    }

    private static func decodeAnswers(_ rawValue: String?) -> [String: [String]]? {
      guard let rawValue else { return nil }
      guard rawValue.utf8.count <= 64 * 1_024,
        let data = rawValue.data(using: .utf8),
        let answers = try? JSONDecoder().decode([String: [String]].self, from: data),
        !answers.isEmpty
      else { return nil }
      return answers
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
      Task { @MainActor in await model.resolveApproval(.direct(approvalID), decision: decision) }
      return true
    }

  }
#endif

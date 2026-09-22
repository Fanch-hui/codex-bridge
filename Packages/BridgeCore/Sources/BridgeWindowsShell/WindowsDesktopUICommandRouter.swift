#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeServiceAppCore
  import Foundation

  enum WindowsDesktopUICommandRouter {
    static func command(for envelope: BridgeDesktopCommandEnvelope) -> MainWindowCommand? {
      let payload = envelope.payload
      switch envelope.command {
      case .ready, .requestStateResync:
        return nil
      case .refresh:
        return .refreshAll
      case .checkAppUpdate:
        return .checkAppUpdate
      case .installAppUpdate:
        return .installAppUpdate
      case .deferAppUpdate:
        return .deferAppUpdate
      case .refreshModels:
        return .refreshModels
      case .setCodexExecutable:
        guard let path = payload.path, path.utf8.count <= 16 * 1_024, !path.contains("\0") else {
          return nil
        }
        return .setCodexExecutablePath(path.trimmingCharacters(in: .whitespacesAndNewlines))
      case .scanAgents:
        return .scanAgents
      case .selectPage:
        return payload.navigation.map(select)
      case .openWorkbench:
        return select(.workbench)
      case .openProjects:
        return select(.projects)
      case .openConnections:
        return select(.connections)
      case .openSettings:
        return select(.settings)
      case .openLogs:
        return select(.logs)
      case .openSystemSettings:
        return nil
      case .openTask:
        return nonEmpty(payload.taskID).map(MainWindowCommand.openTask)
      case .browserBack:
        return .browserBack
      case .browserForward:
        return .browserForward
      case .browserReload:
        return .browserReload
      case .openExternalURL:
        return BridgeDesktopExternalURL.resolve(payload.value).map {
          .openExternalURL($0.absoluteString)
        }
      case .copyTunnelID:
        return .copyTunnelID
      case .openBrowserExternally:
        return .openChatExternally
      case .setBrowserEnabled:
        return payload.enabled.map(MainWindowCommand.setBrowserEnabled)
      case .loadEarlierConversation:
        return nonEmpty(payload.taskID).map(MainWindowCommand.loadEarlierConversation)
      case .refreshConversation:
        return nonEmpty(payload.taskID).map(MainWindowCommand.refreshConversation)
      case .setWorkbenchPermissionMode:
        return nonEmpty(payload.mode).map(MainWindowCommand.setWorkbenchPermissionMode)
      case .selectTask:
        return nonEmpty(payload.taskID).map(MainWindowCommand.selectTaskByID(id:))
      case .refreshTasks:
        return .refreshTasks
      case .interruptTask:
        return nonEmpty(payload.taskID).map(MainWindowCommand.interruptTask)
      case .stopTask:
        return nonEmpty(payload.taskID).map(MainWindowCommand.stopTask)
      case .deleteTask:
        return nonEmpty(payload.taskID).map(MainWindowCommand.deleteTask)
      case .deleteSession:
        return nonEmpty(payload.taskID).map { .deleteSession(taskID: $0) }
      case .steerTask:
        guard let taskID = nonEmpty(payload.taskID), let input = payload.input,
          let mode = nonEmpty(payload.mode),
          ["queued", "interrupt-current-then-continue"].contains(mode)
        else {
          return rejectWorkbenchCommand(envelope)
        }
        return .steerTask(
          id: taskID, input: input, mode: mode, requestID: envelope.requestID
        )
      case .resumeTask:
        guard let taskID = nonEmpty(payload.taskID) else {
          return rejectWorkbenchCommand(envelope)
        }
        return .resumeTask(
          id: taskID, input: payload.input, requestID: envelope.requestID,
          queueIfBusy: payload.queueIfBusy ?? false
        )
      case .handoffTask:
        guard let taskID = nonEmpty(payload.taskID),
          let providerID = nonEmpty(payload.providerID),
          let prompt = nonEmpty(payload.input)
        else {
          return rejectWorkbenchCommand(envelope)
        }
        return .handoffTask(
          id: taskID,
          providerID: providerID,
          prompt: prompt,
          requestID: envelope.requestID
        )
      case .restartTask:
        guard let taskID = nonEmpty(payload.taskID) else {
          return rejectWorkbenchCommand(envelope)
        }
        return .restartTask(
          id: taskID, requestID: envelope.requestID, queueIfBusy: payload.queueIfBusy ?? false)
      case .resolveApproval, .resolveDirectApproval:
        return approvalCommand(envelope.command, payload: payload)
      case .selectProject:
        return nonEmpty(payload.projectID).map(MainWindowCommand.selectProjectByID(id:))
      case .refreshProjects:
        return .refreshProjects
      case .registerProject:
        return registerProject(payload)
      case .removeProject:
        return nonEmpty(payload.projectID).map(MainWindowCommand.removeProject(id:))
      case .saveProjectPolicy:
        guard let projectID = nonEmpty(payload.projectID),
          let read = nonEmpty(payload.readPermission),
          let write = nonEmpty(payload.writePermission),
          let network = nonEmpty(payload.networkPermission)
        else { return nil }
        return .saveProjectPolicyByID(
          projectID: projectID,
          read: read,
          write: write,
          network: network
        )
      case .setProjectCommandMode:
        guard let projectID = nonEmpty(payload.projectID), let mode = nonEmpty(payload.mode) else {
          return nil
        }
        return .setProjectCommandMode(projectID: projectID, mode: mode)
      case .saveProjectCommand:
        guard let projectID = nonEmpty(payload.projectID), let name = payload.name,
          let executable = payload.executable,
          !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return .saveProjectCommand(
          projectID: projectID,
          commandID: optionalValue(payload.commandID),
          name: name,
          executable: executable,
          arguments: payload.arguments ?? [],
          workingDirectory: optionalValue(payload.workingDirectory),
          requiresNetwork: payload.requiresNetwork ?? false,
          risk: nonEmpty(payload.risk) ?? "normal"
        )
      case .removeProjectCommand:
        guard let projectID = nonEmpty(payload.projectID),
          let commandID = nonEmpty(payload.commandID)
        else { return nil }
        return .removeProjectCommand(projectID: projectID, commandID: commandID)
      case .saveProjectBlacklist:
        guard let projectID = nonEmpty(payload.projectID) else { return nil }
        return .saveProjectBlacklist(
          projectID: projectID,
          ruleID: optionalValue(payload.ruleID),
          executable: optionalValue(payload.executable),
          pattern: optionalValue(payload.pattern)
        )
      case .removeProjectBlacklist:
        guard let projectID = nonEmpty(payload.projectID), let ruleID = nonEmpty(payload.ruleID)
        else { return nil }
        return .removeProjectBlacklist(projectID: projectID, ruleID: ruleID)
      case .openThread:
        guard let projectID = nonEmpty(payload.projectID), let threadID = nonEmpty(payload.threadID)
        else { return nil }
        return .openThread(projectID: projectID, threadID: threadID)
      case .selectLog:
        guard let logID = nonEmpty(payload.logID) else { return nil }
        return .selectLogByID(id: logID, taskID: optionalValue(payload.taskID))
      case .refreshLogs:
        return .refreshLogs
      case .setLogSearch:
        return .setLogSearch(text: payload.searchText ?? "")
      case .setLogProjectFilter:
        return .setLogProjectFilterByID(projectID: optionalValue(payload.projectID))
      case .setLogKindFilter:
        guard let kind = nonEmpty(payload.kind),
          ["all", "command", "file", "other"].contains(kind)
        else { return nil }
        return .setLogKindFilterByID(kind: kind)
      case .copyLogs:
        return .copyLogs
      case .setMCPClientEnabled:
        guard let clientID = nonEmpty(payload.clientID), let enabled = payload.enabled else {
          return nil
        }
        return .setMCPClientEnabled(id: clientID, enabled: enabled)
      case .setMCPClientExposure:
        guard let clientID = nonEmpty(payload.clientID), let mode = nonEmpty(payload.exposureMode),
          ["read-only", "full"].contains(mode)
        else { return nil }
        return .setMCPClientExposure(id: clientID, exposureMode: mode)
      case .copyMCPClientConfiguration:
        return nonEmpty(payload.clientID).map(MainWindowCommand.copyMCPClientConfiguration)
      case .copyLocalMCPEndpoint:
        return .copyLocalMCPEndpoint
      case .rotateMCPClientCredential:
        return nonEmpty(payload.clientID).map(MainWindowCommand.rotateMCPClientCredential)
      case .saveDeepSeekHarnessMCPServer:
        return saveDeepSeekHarnessMCPServer(payload)
      case .deleteDeepSeekHarnessMCPServer:
        return nonEmpty(payload.mcpServerID).map(MainWindowCommand.deleteDeepSeekHarnessMCPServer)
      case .setDeepSeekHarnessMCPServerEnabled:
        guard let id = nonEmpty(payload.mcpServerID), let enabled = payload.enabled else {
          return nil
        }
        return .setDeepSeekHarnessMCPServerEnabled(id: id, enabled: enabled)
      case .rotateLocalMCPEndpoint:
        return .rotateLocalMCPEndpoint
      case .configureTunnel:
        guard let tunnelID = nonEmpty(payload.tunnelID), let runtimeKey = payload.runtimeKey,
          !runtimeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return .configureTunnel(tunnelID: tunnelID, runtimeKey: runtimeKey)
      case .connectTunnel:
        return .connectTunnel
      case .disconnectTunnel:
        return .disconnectTunnel
      case .clearTunnel:
        return .clearTunnel
      case .connectAgent:
        guard let providerID = nonEmpty(payload.providerID) else { return nil }
        return .connectAgentFromDesktop(
          providerID: providerID,
          baseURL: AgentConnectionInput.baseURL(payload.baseURL),
          apiKey: AgentConnectionInput.apiKey(payload.apiKey),
          alwaysProceedConfirmed: payload.confirmed == true
        )
      case .registerAgent:
        guard let providerID = nonEmpty(payload.providerID),
          let executable = nonEmpty(payload.executable),
          let displayName = nonEmpty(payload.displayName) ?? nonEmpty(payload.name)
        else { return nil }
        return .registerAgentFromDesktop(
          providerID: providerID,
          displayName: displayName,
          executablePath: executable,
          configurationPath: optionalValue(payload.configurationPath)
        )
      case .beginAgentRegistration:
        return .beginAgentRegistration(providerID: optionalValue(payload.providerID))
      case .selectAgent:
        return nonEmpty(payload.installationID ?? payload.providerID).map(
          MainWindowCommand.selectAgent(id:))
      case .setAgentEnabled:
        guard let installationID = nonEmpty(payload.installationID), let enabled = payload.enabled
        else {
          return nil
        }
        return .setAgentEnabled(id: installationID, enabled: enabled)
      case .reprobeAgent:
        return nonEmpty(payload.installationID).map {
          .reprobeAgent(id: $0, acceptReplacement: payload.acceptReplacement ?? false)
        }
      case .removeAgent:
        return nonEmpty(payload.installationID).map(MainWindowCommand.removeAgent(id:))
      case .refreshAgentModels:
        guard let providerID = nonEmpty(payload.providerID),
          let installationID = nonEmpty(payload.installationID)
        else { return nil }
        return .refreshAgentModelsByID(
          providerID: providerID,
          installationID: installationID
        )
      case .saveAgentDefault:
        guard let providerID = nonEmpty(payload.providerID),
          let permissionMode = nonEmpty(payload.permissionMode)
        else { return nil }
        return .saveAgentDefault(
          providerID: providerID,
          installationID: nonEmpty(payload.installationID),
          modelID: optionalValue(payload.modelID),
          permissionMode: permissionMode,
          effort: optionalValue(payload.effort)
        )
      case .refreshAgentNativePermission, .setAgentNativePermissionMode,
        .addAgentNativePermissionRule, .replaceAgentNativePermissionRule,
        .removeAgentNativePermissionRule, .prepareAgentPermissionRemediation,
        .applyAgentPermissionRemediation:
        return nativePermissionCommand(envelope.command, payload: payload)
      case .saveDirectConfiguration:
        return payload.value.map { .saveDirectConfiguration(json: $0) }
      case .setDirectApprovalMode:
        return nonEmpty(payload.mode).map(MainWindowCommand.setSettingsDirectApprovalMode)
      case .setTaskStartApprovalMode:
        return nonEmpty(payload.mode).map(MainWindowCommand.setSettingsTaskStartApprovalMode)
      case .saveSettings:
        guard let executionModel = nonEmpty(payload.executionModel),
          let executionEffort = payload.executionEffort,
          let accessMode = nonEmpty(payload.accessMode)
        else { return nil }
        return .patchSettings(
          BridgeDesktopSettingsPatch(
            executionModel: executionModel,
            executionEffort: executionEffort,
            accessMode: accessMode,
            fastModeEnabled: payload.fastModeEnabled ?? false
          )
        )
      case .saveCustomInstructions:
        return .saveSettingsInstructions(text: payload.value ?? payload.input ?? "")
      case .setExecutionModel:
        return nonEmpty(payload.modelID ?? payload.executionModel).map {
          .patchSettings(BridgeDesktopSettingsPatch(executionModel: $0))
        }
      case .setExecutionEffort:
        return nonEmpty(payload.effort ?? payload.executionEffort).map {
          .patchSettings(BridgeDesktopSettingsPatch(executionEffort: $0))
        }
      case .setAccessMode:
        return nonEmpty(payload.accessMode).map {
          .patchSettings(BridgeDesktopSettingsPatch(accessMode: $0))
        }
      case .setFastMode:
        guard let enabled = payload.fastModeEnabled ?? payload.enabled else { return nil }
        return .patchSettings(BridgeDesktopSettingsPatch(fastModeEnabled: enabled))
      case .registerService:
        return .registerService
      case .unregisterService:
        return .unregisterService
      case .setKeepServiceRunning:
        return .setKeepServiceRunning(payload.keepServiceRunningAfterExit ?? true)
      case .updateBrowserViewport:
        return payload.viewport.map(MainWindowCommand.updateBrowserViewport)
      case .dismissFeedback:
        return nonEmpty(payload.feedbackID).map(MainWindowCommand.dismissFeedback)
      }
    }

    private static func select(_ navigation: BridgeDesktopNavigation) -> MainWindowCommand {
      .selectPage(index: WindowsMainPage(navigation).rawValue)
    }

    private static func registerProject(_ payload: BridgeDesktopCommandPayload) -> MainWindowCommand
    {
      guard let name = nonEmpty(payload.name), let path = nonEmpty(payload.path) else {
        return .beginProjectRegistration
      }
      return .registerProject(name: name, path: path)
    }

    private static func saveDeepSeekHarnessMCPServer(
      _ payload: BridgeDesktopCommandPayload
    ) -> MainWindowCommand? {
      guard let name = nonEmpty(payload.name),
        let transport = nonEmpty(payload.mcpTransport),
        transport == "stdio" || transport == "http"
      else { return nil }
      let command = nonEmpty(payload.mcpCommand)
      let url = nonEmpty(payload.mcpURL)
      if transport == "stdio" && command == nil { return nil }
      if transport == "http" && url == nil { return nil }
      let id = nonEmpty(payload.mcpServerID) ?? UUID().uuidString.lowercased()
      let environment = (payload.mcpEnvironmentSecrets ?? []).map {
        IPCDeepSeekHarnessMCPSecretInput(name: $0.name, value: $0.value)
      }
      let headers = (payload.mcpHeaderSecrets ?? []).map {
        IPCDeepSeekHarnessMCPSecretInput(name: $0.name, value: $0.value)
      }
      return .saveDeepSeekHarnessMCPServer(
        IPCDeepSeekHarnessMCPServerInput(
          id: id,
          name: name,
          enabled: payload.enabled ?? true,
          transport: transport,
          command: transport == "stdio" ? command : nil,
          args: transport == "stdio" ? payload.arguments ?? [] : [],
          url: transport == "http" ? url : nil,
          environment: environment,
          headers: headers
        )
      )
    }

    private static func nonEmpty(_ value: String?) -> String? {
      guard let value else { return nil }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }

    private static func optionalValue(_ value: String?) -> String? {
      nonEmpty(value)
    }

    private static func rejectWorkbenchCommand(
      _ envelope: BridgeDesktopCommandEnvelope
    ) -> MainWindowCommand {
      .rejectWorkbenchCommand(
        requestID: envelope.requestID,
        command: envelope.command.rawValue,
        taskID: optionalValue(envelope.payload.taskID),
        input: envelope.payload.input
      )
    }

  }

#endif

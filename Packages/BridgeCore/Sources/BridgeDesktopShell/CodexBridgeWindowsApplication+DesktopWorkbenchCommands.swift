#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import BridgeMCP
  import BridgeServiceAppCore

  extension CodexBridgeDesktopApplication {
    static func runDesktopWorkbenchCommand(
      _ envelope: BridgeDesktopCommandEnvelope,
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) -> Bool {
      let payload = envelope.payload
      switch envelope.command {
      case .browserBack:
        onUI { DesktopPlatformHost.browserBack() }
      case .browserForward:
        onUI { DesktopPlatformHost.browserForward() }
      case .browserReload:
        onUI { DesktopPlatformHost.browserReload() }
      case .setBrowserEnabled:
        guard let enabled = payload.enabled else { return true }
        model.setChatBrowserEnabled(enabled)
        updateBrowserMemoryPolicy(model: model)
      case .openBrowserExternally:
        onUI { openChatExternally() }
      case .loadEarlierConversation:
        guard let taskID = BridgeDesktopCommandValue.nonEmpty(payload.taskID),
          model.selectedTaskID == taskID,
          let conversation = model.conversation,
          conversation.taskID == taskID
        else { return true }
        Task { @MainActor in
          await conversation.loadEarlier()
          guard model.selectedTaskID == taskID, model.conversation === conversation else { return }
          model.refreshDisplaySnapshot()
        }
      case .refreshConversation:
        guard let taskID = BridgeDesktopCommandValue.nonEmpty(payload.taskID),
          model.selectedTaskID == taskID,
          let task = model.selectedTask
        else { return true }
        model.openConversation(for: task)
        model.refreshDisplaySnapshot()
      case .setWorkbenchPermissionMode:
        guard let mode = BridgeDesktopCommandValue.nonEmpty(payload.mode),
          let permissionMode = BridgeDesktopWorkbenchPermissionMode(rawValue: mode)
        else { return true }
        Task { @MainActor in await model.selectWorkbenchPermission(permissionMode) }
      case .openTask:
        guard let taskID = BridgeDesktopCommandValue.nonEmpty(payload.taskID) else { return true }
        model.selectTask(id: taskID)
        synchronizeTaskProject(model: model, management: management, auxiliary: auxiliary)
        selectedPage = .workbench
        onUI { DesktopPlatformHost.selectPage(.workbench) }
      case .searchTaskHistory:
        Task { @MainActor in await model.searchTaskHistory(payload) }
      case .selectTaskHistory:
        model.selectTaskHistory(payload.taskID)
      case .selectTask:
        guard let taskID = BridgeDesktopCommandValue.nonEmpty(payload.taskID) else { return true }
        model.selectTask(id: taskID)
        synchronizeTaskProject(model: model, management: management, auxiliary: auxiliary)
        selectedPage = .workbench
        onUI { DesktopPlatformHost.selectPage(.workbench) }
      case .refreshTasks:
        Task { @MainActor in await model.refreshSelectedTask() }
      case .interruptTask:
        guard let taskID = BridgeDesktopCommandValue.nonEmpty(payload.taskID) else { return true }
        Task { @MainActor in await model.interruptTask(id: taskID) }
      case .stopTask:
        guard let taskID = BridgeDesktopCommandValue.nonEmpty(payload.taskID) else { return true }
        Task { @MainActor in await model.stopTask(id: taskID) }
      case .deleteTask:
        guard let taskID = BridgeDesktopCommandValue.nonEmpty(payload.taskID) else { return true }
        Task { @MainActor in await model.deleteTask(id: taskID) }
      case .deleteSession:
        guard let taskID = BridgeDesktopCommandValue.nonEmpty(payload.taskID) else { return true }
        Task { @MainActor in await model.deleteSession(containingTaskID: taskID) }
      case .manageNativeAgentSession:
        manageNativeSession(payload, model: model)
      case .continueNativeAgentSession:
        continueNativeSession(envelope, model: model)
      case .submitDSHTask:
        Task { @MainActor in
          if await model.submitDSHTask(envelope) {
            synchronizeTaskProject(model: model, management: management, auxiliary: auxiliary)
          }
        }
      case .workbenchWorkspace:
        Task { @MainActor in await model.performWorkbenchWorkspace(envelope) }
      case .steerTask:
        steerTask(envelope, model: model)
      case .resumeTask:
        guard let taskID = BridgeDesktopCommandValue.nonEmpty(payload.taskID) else {
          rejectWorkbenchCommand(envelope, model: model)
          return true
        }
        Task { @MainActor in
          await model.resumeTask(
            id: taskID,
            input: payload.input,
            requestID: envelope.requestID,
            queueIfBusy: payload.queueIfBusy ?? false,
            skillNames: payload.skillNames,
            attachmentPaths: payload.attachmentPaths ?? [],
            executionSelection: payload.executionSelection
          )
        }
      case .handoffTask:
        guard let taskID = BridgeDesktopCommandValue.nonEmpty(payload.taskID),
          let providerID = BridgeDesktopCommandValue.nonEmpty(payload.providerID),
          let prompt = payload.input
        else {
          rejectWorkbenchCommand(envelope, model: model)
          return true
        }
        Task { @MainActor in
          await model.handoffTask(
            id: taskID,
            providerID: providerID,
            prompt: prompt,
            requestID: envelope.requestID,
            action: payload.action,
            handoffID: payload.value,
            revision: payload.messageKey
          )
        }
      case .restartTask:
        guard let taskID = BridgeDesktopCommandValue.nonEmpty(payload.taskID) else {
          rejectWorkbenchCommand(envelope, model: model)
          return true
        }
        Task { @MainActor in
          await model.restartTask(
            id: taskID,
            requestID: envelope.requestID,
            queueIfBusy: payload.queueIfBusy ?? false,
            skillNames: payload.skillNames,
            attachmentPaths: payload.attachmentPaths ?? []
          )
        }
      case .resolveApproval, .resolveDirectApproval:
        return runDesktopApprovalCommand(envelope, model: model)
      default:
        return false
      }
      return true
    }

    private static func manageNativeSession(
      _ payload: BridgeDesktopCommandPayload,
      model: WindowsWorkbenchModel
    ) {
      guard let action = BridgeDesktopCommandValue.nonEmpty(payload.action) else { return }
      if action == "close" {
        model.closeNativeSessionDirectory()
        return
      }
      guard let operation = MCPNativeSessionDirectoryOperation(rawValue: action),
        let projectID = BridgeDesktopCommandValue.nonEmpty(payload.projectID),
        let installationID = BridgeDesktopCommandValue.nonEmpty(payload.installationID)
      else { return }
      let sessionID = BridgeDesktopCommandValue.nonEmpty(payload.sessionID)
      guard operation == .list || sessionID != nil else { return }
      let request = MCPNativeSessionDirectoryRequest(
        operation: operation,
        projectID: projectID,
        installationID: installationID,
        sessionID: sessionID,
        offset: max(0, payload.offset ?? 0),
        limit: min(max(1, payload.limit ?? 50), 100),
        title: payload.name,
        confirmed: payload.confirmed ?? false
      )
      Task { @MainActor in await model.manageNativeSessionDirectory(request) }
    }

    private static func continueNativeSession(
      _ envelope: BridgeDesktopCommandEnvelope,
      model: WindowsWorkbenchModel
    ) {
      let payload = envelope.payload
      guard let projectID = BridgeDesktopCommandValue.nonEmpty(payload.projectID),
        let providerID = BridgeDesktopCommandValue.nonEmpty(payload.providerID),
        let installationID = BridgeDesktopCommandValue.nonEmpty(payload.installationID),
        let sessionID = BridgeDesktopCommandValue.nonEmpty(payload.sessionID),
        let prompt = BridgeDesktopCommandValue.nonBlankText(
          payload.input,
          maximumUTF8Bytes: BridgeDesktopCommandValue.maximumWorkbenchPromptBytes
        )
      else {
        rejectWorkbenchCommand(envelope, model: model)
        return
      }
      guard
        let installation = model.agentInstallations.first(where: {
          $0.installationID == installationID && $0.providerID == providerID
        }),
        (installation.nativeSessionOperations
          ?? BridgeDesktopNativeSessionOperations.legacy(for: providerID)).contains("index")
      else {
        rejectWorkbenchCommand(envelope, model: model)
        return
      }
      Task { @MainActor in
        await model.continueNativeAgentSession(
          projectID: projectID,
          providerID: providerID,
          installationID: installationID,
          sessionID: sessionID,
          prompt: prompt
        )
      }
    }

    private static func steerTask(
      _ envelope: BridgeDesktopCommandEnvelope,
      model: WindowsWorkbenchModel
    ) {
      let payload = envelope.payload
      guard payload.executionSelection == nil, payload.modelID == nil, payload.effort == nil,
        payload.permissionMode == nil, payload.attachmentPaths?.isEmpty != false,
        let taskID = BridgeDesktopCommandValue.nonEmpty(payload.taskID),
        let input = payload.input,
        let mode = BridgeDesktopCommandValue.nonEmpty(payload.mode),
        ["queued", "interrupt-current-then-continue"].contains(mode),
        let steerMode = MCPTaskSteerMode(rawValue: mode)
      else {
        rejectWorkbenchCommand(envelope, model: model)
        return
      }
      Task { @MainActor in
        _ = await model.submitSteer(
          taskID: taskID,
          input: input,
          mode: steerMode,
          requestID: envelope.requestID
        )
      }
    }

    private static func rejectWorkbenchCommand(
      _ envelope: BridgeDesktopCommandEnvelope,
      model: WindowsWorkbenchModel
    ) {
      model.rejectWorkbenchCommand(
        requestID: envelope.requestID,
        command: envelope.command.rawValue,
        taskID: BridgeDesktopCommandValue.nonEmpty(envelope.payload.taskID),
        input: envelope.payload.input,
        message: "工作台命令无法执行。"
      )
    }

  }
#endif

#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore

  extension WindowsWorkbenchModel {
    func selectDefaultTaskIfNeeded() {
      guard selectedTaskID == nil, selectedThreadID == nil else { return }
      let contextSessions =
        selectedProjectID.map { projectID in allSessions.filter { $0.projectID == projectID } }
        ?? allSessions
      guard
        let session = contextSessions.first(where: { $0.latestTask.isActive })
          ?? contextSessions.first
      else {
        return
      }
      let task = session.latestTask
      alignContextProject(to: task.projectID)
      selectedTaskID = task.taskID
      selectedThreadID = task.isCodexTask ? task.threadID : nil
      selectedThreadPage = nil
      openConversation(for: task)
    }

    /// Switches the project context and clears the open session; the project is a UI context only.
    public func selectWorkbenchProject(at index: Int) async {
      guard projects.indices.contains(index) else { return }
      let projectID = projects[index].projectID
      guard projectID != selectedProjectID else { return }
      selectedProjectID = projectID
      clearWorkbenchSelection()
      threads = []
      publishDisplay()
      await loadTasks()
    }

    /// Moves the project context to the project of an opened session while keeping that session selected.
    func alignContextProject(to projectID: String) {
      guard selectedProjectID != projectID else { return }
      selectedProjectID = projectID
      threads = []
    }

    /// Keeps a valid context project: the current one, else the default workspace, else the first.
    func reconcileProjectContext() {
      if let selectedProjectID, projects.contains(where: { $0.projectID == selectedProjectID }) {
        return
      }
      selectedProjectID =
        projects.first(where: { $0.projectID == defaultProjectID })?.projectID
        ?? projects.first?.projectID
    }

    public func selectWorkbenchPermission(at index: Int) async {
      guard BridgeDesktopWorkbenchPermissionMode.allCases.indices.contains(index) else {
        return
      }
      await selectWorkbenchPermission(BridgeDesktopWorkbenchPermissionMode.allCases[index])
    }

    public func selectWorkbenchPermission(
      _ permissionMode: BridgeDesktopWorkbenchPermissionMode
    ) async {
      let mode = permissionMode.rawValue
      guard mode != workbenchPermissionMode else { return }
      let previous = workbenchPermissionMode
      workbenchPermissionMode = mode
      actionText = "正在保存权限模式…"
      publishDisplay()
      do {
        try await client.setWorkbenchPermissionMode(mode)
        actionText = "工作台权限模式已保存。"
      } catch {
        workbenchPermissionMode = previous
        actionText = "保存权限模式失败：\(BridgeServiceErrorMessage.message(error))"
      }
      publishDisplay()
    }

    public func selectWorkbenchItem(at index: Int) async {
      let sessions = allSessions
      if sessions.indices.contains(index) {
        selectTask(id: sessions[index].latestTask.taskID)
      }
    }

    public func openWorkbenchThread(threadID: String, projectID: String) async {
      guard connectionState == .connected,
        let projectIndex = projects.firstIndex(where: { $0.projectID == projectID })
      else { return }
      if selectedProjectID != projectID {
        await selectWorkbenchProject(at: projectIndex)
      }
      guard selectedProjectID == projectID else { return }
      await openThread(threadID)
    }

    private func openThread(_ threadID: String) async {
      guard let projectID = selectedProjectID else { return }
      if let task =
        tasks
        .filter({ $0.projectID == projectID && $0.isCodexTask && $0.threadID == threadID })
        .max(by: { $0.updatedAt < $1.updatedAt })
      {
        selectTask(id: task.taskID)
        return
      }

      selectedTaskID = nil
      selectedThreadID = threadID
      selectedThreadPage = nil
      closeConversation()
      actionText = "正在读取 Codex 历史会话…"
      publishDisplay()
      do {
        let page = try await client.readThread(
          IPCThreadReadRequest(
            projectID: projectID,
            threadID: threadID,
            detail: .full
          )
        )
        guard selectedProjectID == projectID, selectedThreadID == threadID,
          selectedTaskID == nil
        else {
          return
        }
        selectedThreadPage = page
        actionText = nil
      } catch {
        guard selectedProjectID == projectID, selectedThreadID == threadID,
          selectedTaskID == nil
        else {
          return
        }
        actionText = "读取会话失败：\(BridgeServiceErrorMessage.message(error))"
      }
      publishDisplay()
    }

    private func clearWorkbenchSelection() {
      selectedTaskID = nil
      selectedThreadID = nil
      selectedThreadPage = nil
      closeConversation()
      conversationWasTerminal = false
    }
  }
#endif

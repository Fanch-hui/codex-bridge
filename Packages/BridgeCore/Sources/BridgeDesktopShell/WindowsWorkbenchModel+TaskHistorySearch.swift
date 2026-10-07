#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeServiceAppCore

  extension WindowsWorkbenchModel {
    var taskHistoryProviderChoices: [BridgeDesktopChoice] {
      [BridgeDesktopChoice(id: "codex", title: "Codex")]
        + agentProviders.filter { $0.providerID != "codex" }.map {
          BridgeDesktopChoice(id: $0.providerID, title: $0.displayName)
        }
    }

    func clearTaskHistorySearch() {
      taskHistorySearchGeneration &+= 1
      taskHistorySearch = WorkbenchTaskHistorySearch()
    }

    func searchTaskHistory(_ payload: BridgeDesktopCommandPayload) async {
      if payload.action == "clear" {
        clearTaskHistorySearch()
        publishDisplay()
        return
      }
      guard connectionState == .connected, let projectID = selectedProjectID else {
        taskHistorySearch.errorMessage = "请连接后台服务并选择项目后搜索。"
        publishDisplay()
        return
      }
      let offset = payload.offset ?? 0
      if offset > 0 {
        guard !taskHistorySearch.isLoading, taskHistorySearch.canLoadMore,
          offset == taskHistorySearch.nextOffset
        else { return }
        taskHistorySearch.isLoading = true
      } else {
        taskHistorySearch.begin(
          search: payload.input, providerID: payload.providerID, status: payload.mode)
      }
      taskHistorySearchGeneration &+= 1
      let generation = taskHistorySearchGeneration
      let request = IPCTaskListRequest(
        projectID: projectID, limit: 51, search: taskHistorySearch.search,
        providerID: taskHistorySearch.providerID, status: taskHistorySearch.status, offset: offset)
      publishDisplay()
      do {
        let page = try await client.tasks(request)
        guard selectedProjectID == projectID, taskHistorySearchGeneration == generation else {
          return
        }
        taskHistorySearch.append(page, limit: 50)
      } catch {
        guard selectedProjectID == projectID, taskHistorySearchGeneration == generation else {
          return
        }
        taskHistorySearch.isLoading = false
        taskHistorySearch.errorMessage = "搜索会话失败：\(BridgeServiceErrorMessage.message(error))"
      }
      publishDisplay()
    }

    func selectTaskHistory(_ taskID: String?) {
      guard let taskID,
        let snapshot = taskHistorySearch.tasks.first(where: { $0.taskID == taskID }),
        snapshot.projectID == selectedProjectID
      else { return }
      selectedHistoryTaskID = taskID
      if !tasks.contains(where: { $0.taskID == taskID }) { tasks.append(snapshot) }
      selectTask(id: taskID)
    }
  }
#endif

import BridgeDesktopUI
import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore

extension BridgeServiceAppModel {
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

  func searchTaskHistory(_ payload: BridgeDesktopCommandPayload) {
    if payload.action == "clear" {
      clearTaskHistorySearch()
      return
    }
    guard let client, connectionState == .connected, let projectID = selectedProjectID else {
      taskHistorySearch.errorMessage = "请连接后台服务并选择项目后搜索。"
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
    Task { [weak self] in
      guard let self else { return }
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
    }
  }

  func selectTaskHistory(_ taskID: String?, requestID: String? = nil, messageID: Int64? = nil) {
    guard let taskID else { return }
    if let snapshot = taskHistorySearch.tasks.first(where: { $0.taskID == taskID }) {
      openHistorySnapshot(snapshot, messageID: messageID)
      recordWorkbenchCommandReceipt(
        requestID: requestID, command: "selectTaskHistory", taskID: taskID, input: nil,
        accepted: true)
      return
    }
    guard let client, connectionState == .connected else {
      rejectWorkbenchCommand(
        requestID: requestID, command: "selectTaskHistory", taskID: taskID, input: nil,
        message: "后台服务未连接。")
      return
    }
    let priorSelection = selectedTaskID
    let priorProject = selectedProjectID
    let priorHistory = selectedHistoryTaskID
    selectedHistoryTaskID = taskID
    Task { [weak self] in
      guard let self else { return }
      do {
        let snapshot: MCPServiceTaskSnapshot
        do {
          snapshot = try await client.task(IPCTaskRequest(taskID: taskID))
        } catch BridgeServiceIPCCodecError.remoteError(let error) where error.code == "unavailable"
        {
          snapshot = try await client.localTaskHistory(IPCTaskRequest(taskID: taskID))
        }
        guard selectedProjectID == priorProject,
          selectedTaskID == priorSelection, selectedHistoryTaskID == taskID
        else { return }
        openHistorySnapshot(snapshot, messageID: messageID)
        recordWorkbenchCommandReceipt(
          requestID: requestID, command: "selectTaskHistory", taskID: taskID, input: nil,
          accepted: true)
      } catch {
        guard selectedProjectID == priorProject, selectedHistoryTaskID == taskID else {
          return
        }
        selectedHistoryTaskID = priorHistory
        let message = "打开历史会话失败：\(BridgeServiceErrorMessage.message(error))"
        errorMessage = message
        rejectWorkbenchCommand(
          requestID: requestID, command: "selectTaskHistory", taskID: taskID, input: nil,
          message: message)
      }
    }
  }

  private func openHistorySnapshot(_ snapshot: MCPServiceTaskSnapshot, messageID: Int64?) {
    selectedHistoryTaskID = snapshot.taskID
    if !tasks.contains(where: { $0.taskID == snapshot.taskID }) { tasks.append(snapshot) }
    openTask(snapshot.taskID)
    if let messageID { conversation?.requestSearchReveal(messageID) }
    selection = .workbench
  }
}

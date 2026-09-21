#if os(Windows)
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore
  import Foundation

  extension WindowsWorkbenchModel {
    func handoffTask(id: String, providerID: String, prompt: String, requestID: String?) async {
      guard connectionState == .connected, let original = task(id: id), original.isTerminal,
        TaskHandoffSummary.providers(
          excluding: original.providerIdentifier, installations: agentInstallations
        ).contains(where: { $0.id == providerID }),
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        prompt.utf8.count <= 32 * 1024
      else {
        rejectWorkbenchCommand(
          requestID: requestID, command: "handoffTask", taskID: id, input: prompt,
          message: "请选择可用 Agent 并检查交接内容。")
        return
      }
      let request = IPCAgentSubmitRequest(
        projectID: original.projectID, providerID: providerID,
        permissionMode: original.permissionMode, prompt: prompt, threadID: nil,
        networkAccess: original.networkAccess,
        permissionModeOverride: original.permissionMode != nil, clientRequestID: requestID)
      setActionTextIfSelected("正在创建接手会话…", taskID: id)
      do {
        let response = try await client.submitAgentTask(request)
        await refreshTasks()
        selectTask(id: response.taskID)
        recordWorkbenchCommandReceipt(
          requestID: requestID, command: "handoffTask", taskID: id, input: prompt, accepted: true)
        reportSuccess("已创建接手会话。", taskID: response.taskID)
      } catch {
        let message = BridgeServiceErrorMessage.message(error)
        rejectWorkbenchCommand(
          requestID: requestID, command: "handoffTask", taskID: id, input: prompt, message: message)
        reportFailure(message, taskID: id)
      }
    }
  }
#endif

import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore
import Foundation

extension BridgeServiceAppModel {
  func handoffTask(
    _ task: MCPServiceTaskSnapshot, providerID: String, prompt: String, requestID: String?
  ) {
    let providers = TaskHandoffSummary.providers(
      excluding: task.providerIdentifier, installations: agentInstallations)
    guard task.isTerminal, providers.contains(where: { $0.id == providerID }),
      !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      prompt.utf8.count <= 32 * 1024
    else {
      rejectWorkbenchCommand(
        requestID: requestID, command: "handoffTask", taskID: task.taskID, input: prompt,
        message: "请选择可用 Agent 并检查交接内容。")
      return
    }
    let request = IPCAgentSubmitRequest(
      projectID: task.projectID, providerID: providerID,
      permissionMode: task.permissionMode, prompt: prompt, threadID: nil,
      networkAccess: task.networkAccess, permissionModeOverride: task.permissionMode != nil,
      clientRequestID: requestID)
    runWorkbenchMutation(
      requestID: requestID, command: "handoffTask", taskID: task.taskID, input: prompt
    ) { [weak self] client in
      guard let self else { return false }
      let response = try await client.submitAgentTask(request)
      await self.refresh(silent: true, includeCatalog: false)
      self.openTask(response.taskID)
      self.postToast("已创建接手会话")
      return true
    }
  }
}

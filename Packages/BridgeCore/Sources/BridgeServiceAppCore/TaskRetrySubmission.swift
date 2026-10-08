import BridgeIPC
import BridgeMCP
import Foundation

public enum TaskRetrySubmission {
  public static func request(
    for task: MCPServiceTaskSnapshot, prompt: String, threadID: String?,
    requestID: String?, queueIfBusy: Bool, skillNames: [String]?,
    attachmentPaths: [String], attachmentSourceTaskID: String?,
    executionSelection: DSHConversationExecutionSelection? = nil
  ) throws -> IPCAgentSubmitRequest {
    let selection: DSHConversationExecutionSelection?
    if let executionSelection {
      guard task.providerIdentifier == "deepseek-harness", threadID != nil else {
        throw DSHWorkbenchTaskSubmission.SubmissionError.invalidInput
      }
      selection = try executionSelection.validated()
    } else {
      selection = nil
    }
    return IPCAgentSubmitRequest(
      projectID: task.projectID, providerID: task.providerIdentifier,
      installationID: task.installationID,
      model: selection == nil ? task.executionModel : selection?.modelID,
      effort: selection == nil ? effort(for: task) : selection?.effort,
      permissionMode: selection?.permissionMode ?? task.permissionMode,
      prompt: prompt, threadID: threadID, skillNames: skillNames,
      modelOverride: selection != nil || modelOverride(for: task),
      clientRequestID: requestID, queueIfBusy: queueIfBusy,
      attachmentPaths: attachmentSourceTaskID == nil && attachmentPaths.isEmpty
        ? nil : attachmentPaths,
      attachmentSourceTaskID: task.isCodexTask ? nil : attachmentSourceTaskID)
  }

  public static func modelOverride(for task: MCPServiceTaskSnapshot) -> Bool {
    guard let model = task.executionModel?.trimmingCharacters(in: .whitespacesAndNewlines),
      !model.isEmpty
    else {
      return false
    }
    return model != "provider-default"
  }

  public static func effort(for task: MCPServiceTaskSnapshot) -> String? {
    guard let effort = task.executionEffort?.trimmingCharacters(in: .whitespacesAndNewlines),
      !effort.isEmpty, effort != "provider-default"
    else {
      return nil
    }
    return effort
  }
}

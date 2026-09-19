import BridgeIPC
import BridgeMCP

/// Platform-neutral text and action rules for desktop task inspectors.
public enum TaskInspectorPresentation {
  public static func metadata(
    for task: MCPServiceTaskSnapshot,
    projectName: String? = nil
  ) -> String {
    var lines = [
      "任务：\(task.workbenchTitle)",
      "状态：\(task.status)",
      "Provider：\(task.providerDisplayName)",
      "项目：\(projectName ?? task.projectID)",
    ]
    if let source = task.sourceDisplayName.nilIfEmpty {
      lines.append("来源：\(source)")
    }
    if let model = task.executionModel?.nilIfEmpty {
      lines.append("模型：\(model)")
    }
    if let effort = task.executionEffort?.nilIfEmpty {
      lines.append("推理强度：\(effort)")
    }
    if let step = task.currentStep?.nilIfEmpty {
      lines.append("当前步骤：\(step)")
    }
    lines.append("网络访问：\(task.networkAccess ? "允许" : "关闭")")
    return lines.joined(separator: "\r\n")
  }

  public static func conversationText(
    entries: [TaskConversationModel.Entry],
    isStreaming: Bool,
    errorMessage: String? = nil
  ) -> String {
    var text =
      entries.isEmpty
      ? (isStreaming ? "等待 Provider 输出…" : "暂无对话记录。")
      : entries.map(messageText).joined(separator: "\r\n\r\n")
    if let error = errorMessage?.nilIfEmpty {
      text += "\r\n\r\n[错误] \(error)"
    }
    return text
  }

  public static func canInterrupt(_ task: MCPServiceTaskSnapshot?) -> Bool {
    task?.expectedControlID != nil
  }

  public static func canSteer(
    _ task: MCPServiceTaskSnapshot?,
    providerSupportsSteer: Bool
  ) -> Bool {
    guard let task, task.expectedControlID != nil else { return false }
    return task.isCodexTask || providerSupportsSteer
  }

  public static func supportsSessionContinuation(
    for task: MCPServiceTaskSnapshot,
    providers: [IPCAgentProviderSummary],
    installations: [IPCAgentInstallationSummary]
  ) -> Bool {
    if task.isCodexTask { return true }
    guard
      providers.contains(where: {
        $0.providerID == task.providerIdentifier && $0.supportsSessionContinuation
      })
    else { return false }
    return installations.contains {
      $0.installationID == task.installationID && $0.providerID == task.providerIdentifier
        && $0.isEnabled && $0.effectiveCapabilities.contains("lifecycle.session_continue")
    }
  }

  public static func canResume(
    _ task: MCPServiceTaskSnapshot?,
    providerSupportsSessionContinuation: Bool
  ) -> Bool {
    guard let task, task.canResumeSession else { return false }
    return task.isCodexTask || providerSupportsSessionContinuation
  }

  public static func steerValidationMessage(_ input: String) -> String? {
    guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return "补充指令不能为空。"
    }
    guard input.utf8.count <= IPCTaskSteerRequest.maximumInputBytes else {
      return "补充指令超过 32768 字节限制。"
    }
    guard !input.contains("\0") else {
      return "补充指令包含非法空字符。"
    }
    return nil
  }

  public static func shouldApplyTaskActionResult(
    for requestTaskID: String,
    selectedTaskID: String?
  ) -> Bool {
    requestTaskID == selectedTaskID
  }

  private static func messageText(_ entry: TaskConversationModel.Entry) -> String {
    let role = entry.role == "user" ? "用户" : "Agent"
    var content = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
    if let toolName = entry.toolName?.nilIfEmpty {
      let tool = entry.toolStatus?.nilIfEmpty.map { "\(toolName)（\($0)）" } ?? toolName
      let prefix = "[工具：\(tool)]"
      content = content.isEmpty ? prefix : "\(prefix)\r\n\(content)"
    }
    return "\(role)：\(content)"
  }
}

extension String {
  fileprivate var nilIfEmpty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}

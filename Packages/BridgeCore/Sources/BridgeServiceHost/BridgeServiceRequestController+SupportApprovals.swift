import BridgeCodexService
import BridgeIPC
import BridgeMCP
import BridgeServiceApplication
import Foundation

extension BridgeServiceRequestController {
  static func approvalSummary(
    _ approval: ExecutionApprovalRequest
  ) -> IPCApprovalSummary {
    IPCApprovalSummary(
      approvalID: approval.id,
      taskID: approval.taskID.rawValue,
      threadID: approval.binding.threadID,
      turnID: approval.binding.turnID,
      itemID: approval.itemID,
      kind: approval.kind.rawValue,
      title: approval.title,
      summary: approval.summary,
      displayCommand: approval.displayCommand,
      relativePaths: approval.relativePaths,
      reason: approval.reason,
      decisionOptions: approval.availableDecisions.map(\.rawValue),
      questions: approval.questions.isEmpty
        ? nil
        : approval.questions.map { question in
          IPCUserInputQuestion(
            id: question.id, header: question.header, question: question.question,
            inputType: question.inputType,
            isOther: question.isOther, isSecret: question.isSecret,
            allowsMultiple: question.allowsMultiple, isRequired: question.isRequired,
            options: question.options.map {
              IPCUserInputOption(label: $0.label, description: $0.description)
            }
          )
        }
    )
  }

  static func taskStartApprovalSummary(
    _ approval: BridgeServiceApplication.PendingTaskStartApproval
  ) -> IPCApprovalSummary {
    let prompt = String(decoding: approval.prompt.utf8.prefix(4 * 1_024), as: UTF8.self)
    let clientLabel: String
    switch approval.clientID {
    case MCPClientID.chatGPT.rawValue:
      clientLabel = "ChatGPT"
    case MCPClientID.qwenStudio.rawValue:
      clientLabel = "Qwen"
    default:
      clientLabel = "远程客户端"
    }
    let permission = approval.permissionMode == "read-only" ? "只读" : "完整（读写与联网）"
    return IPCApprovalSummary(
      approvalID: approval.approvalID,
      taskID: approval.taskID,
      threadID: "",
      turnID: "",
      itemID: approval.taskID,
      kind: "task_start",
      title: "\(clientLabel)请求调用 \(approval.providerDisplayName)",
      summary: prompt,
      reason: "项目：\(approval.projectID) · 权限：\(permission)",
      decisionOptions: ["allow", "deny"],
      oneTimeToolAutoApprovalAvailable: approval.oneTimeToolAutoApprovalAvailable
    )
  }

}

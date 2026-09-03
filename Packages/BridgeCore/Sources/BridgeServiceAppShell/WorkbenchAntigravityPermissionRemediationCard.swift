import BridgeIPC
import BridgeMCP
import SwiftUI

struct WorkbenchAntigravityPermissionRemediationCard: View {
  @ObservedObject var model: BridgeServiceAppModel
  @ObservedObject var conversation: TaskConversationModel
  let task: MCPServiceTaskSnapshot

  @State private var remediation: IPCAgentPermissionRemediationResponse?
  @State private var isPreparing = false
  @State private var isApplying = false
  @State private var showConfirmation = false
  @State private var didApply = false

  var body: some View {
    if let deniedTool {
      NativeCard {
        VStack(alignment: .leading, spacing: 10) {
          Label("AGY 工具权限被拒绝", systemImage: "exclamationmark.shield.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)

          VStack(alignment: .leading, spacing: 3) {
            Text(deniedTool.toolName ?? "AGY 工具")
              .font(.caption.weight(.semibold))
            if let arguments = deniedTool.toolArguments, !arguments.isEmpty {
              Text(arguments)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
            }
          }

          if didApply {
            Label(
              "AGY Global 权限已更新，仅对新任务生效。请在 ChatGPT/Qwen 中重新提交或续接任务。",
              systemImage: "checkmark.shield.fill"
            )
            .font(.caption2)
            .foregroundStyle(.green)
          } else {
            Button {
              prepareRemediation(for: deniedTool)
            } label: {
              if isPreparing || isApplying {
                ProgressView()
                  .controlSize(.small)
              } else {
                Label("允许此工具并写入 AGY Global 配置", systemImage: "checkmark.shield")
              }
            }
            .controlSize(.small)
            .disabled(isPreparing || isApplying)
          }
        }
      }
      .alert("写入 AGY Global 允许规则？", isPresented: $showConfirmation) {
        Button("允许并保存", role: .destructive) {
          applyRemediation()
        }
        Button("取消", role: .cancel) {
          remediation = nil
        }
      } message: {
        Text(confirmationMessage)
      }
    }
  }

  private var deniedTool: TaskConversationModel.Entry? {
    conversation.entries.last {
      $0.kind == "tool_call" && $0.toolStatus == "declined"
    }
  }

  private var confirmationMessage: String {
    let rule = remediation?.displayRule ?? "待确认规则"
    return
      "将写入：\(rule)\n\n这是当前 macOS 用户的 AGY Global 配置，会影响使用同一 HOME 的其他 AGY CLI 任务。Bridge 的项目 Read Only/Write 硬策略保持不变。"
  }

  private func prepareRemediation(for entry: TaskConversationModel.Entry) {
    guard !isPreparing else { return }
    isPreparing = true
    Task {
      remediation = await model.permissionRemediation(taskID: task.taskID, messageKey: entry.key)
      isPreparing = false
      showConfirmation = remediation != nil
    }
  }

  private func applyRemediation() {
    guard let remediation, !isApplying else { return }
    isApplying = true
    Task {
      didApply = await model.applyPermissionRemediation(remediation)
      isApplying = false
      if didApply {
        self.remediation = nil
      }
    }
  }
}

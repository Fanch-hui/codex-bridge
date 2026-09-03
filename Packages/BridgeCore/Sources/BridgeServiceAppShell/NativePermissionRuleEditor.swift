import BridgeIPC
import SwiftUI

struct NativePermissionRuleEditorItem: Identifiable {
  let id: String
  let ruleID: String?
  let effect: String
  let action: String
  let target: String

  init(effect: String) {
    id = UUID().uuidString
    ruleID = nil
    self.effect = effect
    action = "command"
    target = ""
  }

  init(rule: IPCAgentNativePermissionRuleSummary) {
    id = rule.ruleID
    ruleID = rule.ruleID
    effect = rule.effect
    action = rule.action
    target = rule.target
  }
}

struct NativePermissionRuleEditor: View {
  @Environment(\.dismiss) private var dismiss

  let item: NativePermissionRuleEditorItem
  let availableActions: [String]
  let isSaving: Bool
  let onSave: (String, String, String) -> Void

  @State private var effect: String
  @State private var action: String
  @State private var target: String
  @State private var showRiskConfirmation = false

  init(
    item: NativePermissionRuleEditorItem,
    availableActions: [String],
    isSaving: Bool,
    onSave: @escaping (String, String, String) -> Void
  ) {
    self.item = item
    self.availableActions = availableActions
    self.isSaving = isSaving
    self.onSave = onSave
    _effect = State(initialValue: item.effect)
    _action = State(initialValue: item.action)
    _target = State(initialValue: item.target)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Label(
          item.ruleID == nil ? "新增 AGY Global 规则" : "编辑 AGY Global 规则",
          systemImage: "shield.lefthalf.filled"
        )
        .font(.headline)
        Spacer()
      }

      Picker("效果", selection: $effect) {
        Text("Allow").tag("allow")
        Text("Ask").tag("ask")
        Text("Deny").tag("deny")
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: 280)

      Picker("动作", selection: $action) {
        ForEach(availableActions, id: \.self) { value in
          Text(actionTitle(value)).tag(value)
        }
      }
      .pickerStyle(.menu)
      .frame(maxWidth: 280)

      VStack(alignment: .leading, spacing: 6) {
        Text("目标")
          .font(.caption.weight(.semibold))
        TextField(targetPlaceholder, text: $target)
          .textFieldStyle(.roundedBorder)
        Text(targetHelp)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Divider()

      HStack {
        Button("取消", role: .cancel) { dismiss() }
        Spacer()
        Button(item.ruleID == nil ? "添加规则" : "保存规则") {
          if requiresRiskConfirmation {
            showRiskConfirmation = true
          } else {
            save()
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(normalizedTarget.isEmpty || isSaving)
      }
    }
    .padding(22)
    .frame(width: 500)
    .alert("保存高风险 Global 规则？", isPresented: $showRiskConfirmation) {
      Button("保存规则", role: .destructive) { save() }
      Button("取消", role: .cancel) {}
    } message: {
      Text(
        "该规则的范围较广，会影响使用同一 HOME 的其他 AGY CLI 任务。Bridge 的项目 Read Only/Write 硬策略保持不变。"
      )
    }
  }

  private var normalizedTarget: String {
    target.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var requiresRiskConfirmation: Bool {
    if action == "unsandboxed" || normalizedTarget.contains("*") { return true }
    if action == "mcp", !normalizedTarget.contains("/") { return true }
    if action == "command", normalizedTarget.split(whereSeparator: \.isWhitespace).count <= 1 {
      return true
    }
    if action == "read_url" || action == "execute_url" {
      let host = normalizedTarget.split(separator: ":", maxSplits: 1).first ?? ""
      return !host.contains(".")
    }
    return false
  }

  private var targetPlaceholder: String {
    switch action {
    case "command": "例如：swift test"
    case "read_url", "execute_url": "例如：example.com"
    case "mcp": "例如：server/tool"
    case "read_file", "write_file": "例如：/path/to/project/*"
    case "unsandboxed": "需要脱离沙箱的目标"
    default: "权限目标"
    }
  }

  private var targetHelp: String {
    switch action {
    case "command": "输入需要允许、询问或拒绝的命令前缀。"
    case "read_url": "控制读取指定主机的网络内容。"
    case "execute_url": "控制在指定主机执行浏览器操作。"
    case "mcp": "使用 server/tool；server/* 会允许整个 MCP Server。"
    case "read_file", "write_file": "输入 AGY 规则使用的文件路径目标。"
    case "unsandboxed": "允许目标脱离 AGY 沙箱，保存前会再次确认。"
    default: "输入该动作的规则目标。"
    }
  }

  private func actionTitle(_ value: String) -> String {
    switch value {
    case "command": "命令"
    case "read_url": "读取网页"
    case "execute_url": "操作网页"
    case "mcp": "MCP 工具"
    case "read_file": "读取文件"
    case "write_file": "写入文件"
    case "unsandboxed": "脱离沙箱"
    default: value
    }
  }

  private func save() {
    onSave(effect, action, normalizedTarget)
    dismiss()
  }
}

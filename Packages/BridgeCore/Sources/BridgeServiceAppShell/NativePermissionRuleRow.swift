import BridgeIPC
import SwiftUI

struct NativePermissionRuleRow: View {
  let rule: IPCAgentNativePermissionRuleSummary
  let isSaving: Bool
  let edit: () -> Void
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(rule.action)
          .font(.caption.weight(.semibold))
        Text(rule.target)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .textSelection(.enabled)
      }
      Spacer()
      if rule.isRedacted {
        Image(systemName: "eye.slash")
          .foregroundStyle(.secondary)
          .help("规则目标已脱敏")
      }
      if rule.isEditable {
        Button(action: edit) {
          Image(systemName: "pencil")
        }
        .buttonStyle(.borderless)
        .disabled(isSaving)
        .help("编辑规则")
      }
      Button(role: .destructive, action: remove) {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .disabled(isSaving)
      .help("删除规则")
    }
    .padding(8)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
  }
}

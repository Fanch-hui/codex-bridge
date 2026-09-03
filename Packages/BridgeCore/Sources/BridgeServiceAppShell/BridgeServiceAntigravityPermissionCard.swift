import BridgeIPC
import SwiftUI

struct BridgeServiceAntigravityPermissionCard: View {
  @ObservedObject var model: BridgeServiceAppModel

  @State private var selectedInstallationID = ""
  @State private var selectedEffect = "allow"
  @State private var editor: NativePermissionRuleEditorItem?
  @State private var pendingMode: String?

  var body: some View {
    if !installations.isEmpty {
      NativeCard {
        VStack(alignment: .leading, spacing: 14) {
          header
          installationPicker
          if let snapshot {
            modePicker(snapshot)
            Text("规则优先级：Deny > Ask > Allow")
              .font(.caption2)
              .foregroundStyle(.secondary)
            warningList(snapshot.warnings)
            Divider()
            rulesEditor(snapshot)
          } else if isLoading {
            ProgressView("正在读取 AGY Global 权限…")
              .controlSize(.small)
          } else {
            Text("尚未读取 AGY Global 权限。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.orange)
              .textSelection(.enabled)
          }
          Text("直接修改当前 AGY 安装使用的 Global 配置，仅对之后启动的新任务生效。")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .task(id: installationID) {
        await model.loadNativePermissionPolicy(installationID: installationID)
      }
      .sheet(item: $editor) { item in
        NativePermissionRuleEditor(
          item: item,
          availableActions: snapshot?.availableActions ?? [],
          isSaving: isSaving
        ) { effect, action, target in
          saveRule(item: item, effect: effect, action: action, target: target)
        }
      }
      .alert("启用 Always Proceed？", isPresented: pendingModePresented) {
        Button("启用", role: .destructive) {
          guard let pendingMode else { return }
          setToolPermission(pendingMode)
          self.pendingMode = nil
        }
        Button("取消", role: .cancel) { pendingMode = nil }
      } message: {
        Text(
          "这会修改当前 macOS 用户的 AGY Global 配置，并影响使用同一 HOME 的其他 AGY CLI 任务。Bridge 的项目 Read Only/Write 硬策略保持不变。"
        )
      }
    }
  }

  private var header: some View {
    HStack {
      Label("AGY CLI Global 工具权限", systemImage: "shield.lefthalf.filled")
        .font(.headline)
      Spacer()
      if isLoading || isSaving {
        ProgressView()
          .controlSize(.small)
      }
      Button {
        Task { await model.loadNativePermissionPolicy(installationID: installationID) }
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.borderless)
      .disabled(isLoading || isSaving)
      .help("重新读取 AGY Global 权限")
      .accessibilityLabel("刷新 AGY Global 权限")
    }
  }

  @ViewBuilder
  private var installationPicker: some View {
    if installations.count > 1 {
      Picker("安装", selection: installationBinding) {
        ForEach(installations, id: \.installationID) { installation in
          Text(installation.displayName).tag(installation.installationID)
        }
      }
      .pickerStyle(.menu)
      .frame(maxWidth: 280)
      .disabled(isLoading || isSaving)
    } else if let installation = installations.first {
      LabeledContent("安装", value: installation.displayName)
        .font(.caption)
    }
  }

  private func modePicker(_ snapshot: IPCAgentNativePermissionPolicyResponse) -> some View {
    Picker("工具执行策略", selection: modeBinding(snapshot)) {
      ForEach(snapshot.availableModes, id: \.modeID) { mode in
        Text(mode.displayName).tag(mode.modeID)
      }
    }
    .pickerStyle(.menu)
    .frame(maxWidth: 280)
    .disabled(isSaving)
  }

  @ViewBuilder
  private func warningList(_ warnings: [String]) -> some View {
    ForEach(warnings, id: \.self) { warning in
      Label(warning, systemImage: "exclamationmark.shield")
        .font(.caption2)
        .foregroundStyle(.orange)
    }
  }

  private func rulesEditor(_ snapshot: IPCAgentNativePermissionPolicyResponse) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Picker("规则效果", selection: $selectedEffect) {
          Text("Allow").tag("allow")
          Text("Ask").tag("ask")
          Text("Deny").tag("deny")
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        Button {
          editor = NativePermissionRuleEditorItem(effect: selectedEffect)
        } label: {
          Label("新增规则", systemImage: "plus")
        }
        .controlSize(.small)
        .disabled(isSaving)
      }

      let visibleRules = snapshot.rules.filter { $0.effect == selectedEffect }
      if visibleRules.isEmpty {
        Text("当前没有 \(selectedEffect.capitalized) 规则。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 8)
      } else {
        ForEach(visibleRules, id: \.ruleID) { rule in
          NativePermissionRuleRow(
            rule: rule,
            isSaving: isSaving,
            edit: { editor = NativePermissionRuleEditorItem(rule: rule) },
            remove: { removeRule(rule) }
          )
        }
      }
    }
  }

  private var installations: [IPCAgentInstallationSummary] {
    model.agentInstallations.filter {
      $0.providerID == "antigravity" && $0.isEnabled && $0.availability == "available"
    }
  }

  private var installationID: String {
    if installations.contains(where: { $0.installationID == selectedInstallationID }) {
      return selectedInstallationID
    }
    if let focused = model.focusedAgentNativePermissionInstallationID,
      installations.contains(where: { $0.installationID == focused })
    {
      return focused
    }
    return installations.first?.installationID ?? ""
  }

  private var installationBinding: Binding<String> {
    Binding(get: { installationID }, set: { selectedInstallationID = $0 })
  }

  private var snapshot: IPCAgentNativePermissionPolicyResponse? {
    model.nativePermissionPolicy(installationID: installationID)
  }

  private var isLoading: Bool {
    model.isLoadingNativePermissionPolicy(installationID)
  }

  private var isSaving: Bool {
    model.isSavingNativePermissionPolicy(installationID)
  }

  private var errorMessage: String? {
    model.agentNativePermissionErrors[installationID]
  }

  private func modeBinding(
    _ snapshot: IPCAgentNativePermissionPolicyResponse
  ) -> Binding<String> {
    Binding(
      get: { snapshot.toolPermission },
      set: { mode in
        guard mode != snapshot.toolPermission else { return }
        if snapshot.availableModes.first(where: { $0.modeID == mode })?.requiresConfirmation
          == true
        {
          pendingMode = mode
        } else {
          setToolPermission(mode)
        }
      }
    )
  }

  private var pendingModePresented: Binding<Bool> {
    Binding(
      get: { pendingMode != nil },
      set: { if !$0 { pendingMode = nil } }
    )
  }

  private func setToolPermission(_ mode: String) {
    guard let snapshot else { return }
    model.updateNativePermissionPolicy(
      IPCAgentNativePermissionMutationRequest(
        installationID: installationID,
        expectedRevision: snapshot.revision,
        operation: .setToolPermission,
        toolPermission: mode
      )
    )
  }

  private func saveRule(
    item: NativePermissionRuleEditorItem,
    effect: String,
    action: String,
    target: String
  ) {
    guard let snapshot else { return }
    model.updateNativePermissionPolicy(
      IPCAgentNativePermissionMutationRequest(
        installationID: installationID,
        expectedRevision: snapshot.revision,
        operation: item.ruleID == nil ? .addRule : .replaceRule,
        ruleID: item.ruleID,
        effect: effect,
        action: action,
        target: target
      )
    )
  }

  private func removeRule(_ rule: IPCAgentNativePermissionRuleSummary) {
    guard let snapshot else { return }
    model.updateNativePermissionPolicy(
      IPCAgentNativePermissionMutationRequest(
        installationID: installationID,
        expectedRevision: snapshot.revision,
        operation: .removeRule,
        ruleID: rule.ruleID
      )
    )
  }
}

import BridgeIPC
import BridgeMCP
import SwiftUI

@MainActor
struct BridgeServiceWorkbenchInspectorContext {
  let currentActiveTask: MCPServiceTaskSnapshot?
  let currentTask: MCPServiceTaskSnapshot?
  let projectTasks: [MCPServiceTaskSnapshot]
  let steerableTask: MCPServiceTaskSnapshot?
  let canSubmitSteer: Bool
  let canInterruptAndContinue: Bool
  let providerSubtitle: String
  let activity: CodexActivityPresentation

  init(model: BridgeServiceAppModel, steerInput: String) {
    let activeTask = Self.currentActiveTask(in: model)
    let selectedTask = Self.currentTask(in: model, fallback: activeTask)
    let projectTasks = model.tasks.filter { task in
      model.selectedProjectID == nil || task.projectID == model.selectedProjectID
    }

    currentActiveTask = activeTask
    currentTask = selectedTask
    self.projectTasks = projectTasks
    steerableTask = Self.steerableTask(in: model, task: selectedTask)
    canSubmitSteer = Self.canSubmitSteer(steerInput)
    canInterruptAndContinue = Self.canInterruptAndContinue(in: model, task: selectedTask)
    providerSubtitle = Self.providerSubtitle(for: selectedTask)
    activity = CodexActivityPresentation(
      task: selectedTask ?? activeTask,
      activity: model.conversation?.activity ?? .idle
    )
  }

  private static func currentActiveTask(in model: BridgeServiceAppModel) -> MCPServiceTaskSnapshot?
  {
    if let selectedTaskID = model.selectedTaskID {
      return model.tasks.first(where: { $0.taskID == selectedTaskID && $0.isActive })
    }
    if let taskID = model.conversation?.taskID {
      return model.tasks.first(where: { $0.taskID == taskID && $0.isActive })
    }
    if let selectedThreadID = model.selectedThreadID {
      return model.tasks.first(where: {
        $0.threadID == selectedThreadID && $0.isCodexTask && $0.isRunning
      })
    }
    return model.tasks.first(where: {
      $0.projectID == model.selectedProjectID && $0.isRunning
    }) ?? model.tasks.first(where: \.isRunning)
  }

  private static func currentTask(
    in model: BridgeServiceAppModel,
    fallback: MCPServiceTaskSnapshot?
  ) -> MCPServiceTaskSnapshot? {
    if let selectedTaskID = model.selectedTaskID,
      let task = model.tasks.first(where: { $0.taskID == selectedTaskID })
    {
      return task
    }
    if let taskID = model.conversation?.taskID,
      let task = model.tasks.first(where: { $0.taskID == taskID })
    {
      return task
    }
    if let selectedThreadID = model.selectedThreadID,
      let task = model.tasks.first(where: {
        $0.threadID == selectedThreadID && $0.isCodexTask
      })
    {
      return task
    }
    return fallback
  }

  private static func steerableTask(
    in model: BridgeServiceAppModel,
    task: MCPServiceTaskSnapshot?
  ) -> MCPServiceTaskSnapshot? {
    guard let task,
      task.expectedControlID != nil
    else { return nil }
    if task.isExternalAgentTask {
      guard let providerID = task.providerID,
        model.agentProviders.first(where: { $0.providerID == providerID })?.supportsSteer == true
      else { return nil }
    }
    return task
  }

  private static func canSubmitSteer(_ input: String) -> Bool {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    return !text.isEmpty && input.utf8.count <= IPCTaskSteerRequest.maximumInputBytes
      && !input.contains("\0")
  }

  private static func canInterruptAndContinue(
    in model: BridgeServiceAppModel,
    task: MCPServiceTaskSnapshot?
  ) -> Bool {
    guard let installationID = task?.installationID else { return false }
    return model.agentInstallations.first(where: {
      $0.installationID == installationID
    })?.effectiveCapabilities.contains("lifecycle.steer_interrupt_and_continue") == true
  }

  private static func providerSubtitle(for task: MCPServiceTaskSnapshot?) -> String {
    guard let task, task.isExternalAgentTask else {
      return "远程 MCP 调用 Codex 或外部 Agent 时，默认在当前选择的项目中执行"
    }
    let permission = WorkbenchAgentPermissionPresentation.title(task.permissionMode)
    return "\(task.providerDisplayName) 原生 \(permission)，在当前项目执行并在此处显示实时结果"
  }
}

struct BridgeServiceWorkbenchInspectorPane: View {
  @ObservedObject var model: BridgeServiceAppModel
  @Binding var steerInput: String
  let pendingApprovalIDs: [String]

  var body: some View {
    let context = BridgeServiceWorkbenchInspectorContext(
      model: model,
      steerInput: steerInput
    )

    VStack(spacing: 0) {
      BridgeServiceWorkbenchInspectorHeader(
        model: model,
        context: context
      )
      .fixedSize(horizontal: false, vertical: true)
      Divider()
      if !pendingApprovalIDs.isEmpty {
        BridgeServiceWorkbenchApprovalTray(model: model)
          .fixedSize(horizontal: false, vertical: true)
          .layoutPriority(2)
        Divider()
      }
      BridgeServiceWorkbenchInspectorLiveRegion(
        model: model,
        context: context,
        steerInput: $steerInput
      )
      .layoutPriority(1)
    }
    .frame(minHeight: 0, maxHeight: .infinity)
    .background(Color(nsColor: .controlBackgroundColor))
  }

}

struct BridgeServiceWorkbenchInspectorHeader: View {
  @ObservedObject var model: BridgeServiceAppModel
  let context: BridgeServiceWorkbenchInspectorContext
  @State private var showDeleteConfirmation = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 8) {
        Image(systemName: "folder.fill")
          .font(.system(size: 14))
          .foregroundStyle(.blue)

        Menu {
          ForEach(model.projects, id: \.projectID) { project in
            Button {
              model.selectProject(project.projectID)
            } label: {
              if project.projectID == model.selectedProjectID {
                Label(project.name, systemImage: "checkmark")
              } else {
                Text(project.name)
              }
            }
          }
        } label: {
          Text(model.projectName(for: model.selectedProjectID ?? ""))
            .font(.subheadline.weight(.bold))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 180, alignment: .leading)
            .foregroundStyle(.primary)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 180, alignment: .leading)

        Spacer()

        if let task = context.currentTask {
          StatusBadge(task.providerDisplayName, tone: .neutral)
          StatusBadge(task.sourceDisplayName, tone: .neutral)
          TaskStatusLabel(status: task.status, providerID: task.providerID)
        } else if model.runningTaskCount > 0 {
          StatusBadge("运行中", tone: .running)
        } else {
          StatusBadge("就绪", tone: .success)
        }
      }

      Text(context.providerSubtitle)
        .font(.caption2)
        .foregroundStyle(.secondary)

      WorkbenchPermissionModePicker(model: model)

      if let task = context.currentTask, let modelLabel = taskModelLabel(for: task) {
        Label {
          Text("使用模型 \(modelLabel)")
            .lineLimit(1)
            .truncationMode(.middle)
        } icon: {
          Image(systemName: "cpu")
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .help("当前任务模型记录：\(modelLabel)")
        .accessibilityLabel("当前任务实际使用模型：\(modelLabel)")
      }

      HStack(spacing: 6) {
        WorkbenchAgentTaskPicker(
          model: model,
          tasks: context.projectTasks,
          threads: model.threads
        )
        Spacer()
        if let activeTask = context.currentActiveTask, canInterrupt(activeTask) {
          Button("中断", role: .destructive) {
            model.interruptTask(activeTask)
          }
          .buttonStyle(.bordered)
          .controlSize(.mini)
        } else if let currentTask = context.currentTask, currentTask.isTerminal {
          Button(role: .destructive) {
            showDeleteConfirmation = true
          } label: {
            Image(systemName: "trash")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.borderless)
          .help("删除当前会话")
          .accessibilityLabel("删除当前会话")
        }
      }
    }
    .padding(12)
    .background(Color(nsColor: .windowBackgroundColor))
    .alert("删除当前会话？", isPresented: $showDeleteConfirmation) {
      Button("删除", role: .destructive) {
        if let task = context.currentTask {
          let sessionID = task.effectiveSessionID ?? task.taskID
          model.deleteSession(sessionID, inProject: task.projectID)
        }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("该操作会删除此会话在 Codex Bridge 中保存的全部轮次任务、事件和对话记录，无法撤销。")
    }
  }

  private func canInterrupt(_ task: MCPServiceTaskSnapshot) -> Bool {
    task.expectedControlID != nil
  }

  private func taskModelLabel(for task: MCPServiceTaskSnapshot) -> String? {
    let displayName: String?
    if task.isCodexTask {
      displayName = model.models.first(where: { $0.modelID == task.executionModel })?.displayName
    } else {
      displayName =
        model.agentModelOptions(for: task.providerIdentifier)
        .first(where: { $0.modelID == task.executionModel })?.displayName
    }
    return WorkbenchTaskModelPresentation.label(
      modelID: task.executionModel,
      effort: task.executionEffort,
      displayName: displayName
    )
  }
}

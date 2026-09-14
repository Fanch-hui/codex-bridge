import BridgeMCP
import BridgeServiceAppCore
import SwiftUI

package typealias WorkbenchAgentTaskPickerContent = WorkbenchSessionCatalog

struct WorkbenchAgentTaskPicker: View {
  @ObservedObject var model: BridgeServiceAppModel
  let tasks: [MCPServiceTaskSnapshot]

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "list.bullet.rectangle")
        .font(.caption2)
        .foregroundStyle(.secondary)

      if itemCount == 0 {
        Text("暂无 Agent 会话")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Menu {
          ForEach(WorkbenchSessionCatalog.groupedSessions(tasks: tasks)) { group in
            Section {
              ForEach(group.sessions) { session in
                Button {
                  model.openSession(session)
                } label: {
                  Label(
                    WorkbenchTaskTextPresentation.sessionMenuTitle(
                      title: session.title,
                      turnCount: session.turnCount
                    ),
                    systemImage: isSessionSelected(session)
                      ? "checkmark" : session.providerSystemImage
                  )
                }
              }
            } header: {
              Label(group.providerDisplayName + " 会话", systemImage: group.providerSystemImage)
            }
          }

        } label: {
          Text(selectedItemLabel)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 240, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 240, alignment: .leading)
        .help(selectedItemLabel)
        .accessibilityLabel("当前 Agent 会话：\(selectedItemLabel)")
      }
    }
  }

  private func isSessionSelected(_ session: WorkbenchSessionItem) -> Bool {
    session.tasks.contains(where: { $0.taskID == model.selectedTaskID })
  }

  private var selectedItemLabel: String {
    if let session = WorkbenchSessionCatalog.selectedSession(
      tasks: tasks,
      selectedTaskID: model.selectedTaskID
    ) {
      let title = WorkbenchTaskTextPresentation.sessionMenuTitle(
        title: session.title,
        turnCount: session.turnCount,
        maximumCharacters: 30
      )
      return "\(session.providerDisplayName) · \(title)"
    }
    return "选择 Agent 会话（\(itemCount)）"
  }

  private var itemCount: Int {
    WorkbenchSessionCatalog.sessions(tasks: tasks).count
  }
}

struct WorkbenchExternalTaskCard: View {
  let task: MCPServiceTaskSnapshot

  var body: some View {
    NativeCard {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Label(task.providerDisplayName, systemImage: task.providerSystemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
          Spacer()
          TaskStatusLabel(status: task.status, providerID: task.providerID)
        }

        if let title = WorkbenchTaskTextPresentation.cardTitle(for: task) {
          Text(title)
            .font(.caption)
            .lineLimit(3)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let modelLabel = WorkbenchTaskModelPresentation.label(
          modelID: task.executionModel,
          effort: task.executionEffort,
          displayName: nil
        ) {
          Label("使用模型 \(modelLabel)", systemImage: "cpu")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        Text("原生 \(WorkbenchAgentPermissionPresentation.title(task.permissionMode))")
          .font(.caption2)
          .foregroundStyle(.secondary)

        if task.providerIdentifier == "deepseek-harness" {
          Text("每个任务使用独立会话")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .help("DeepSeek Harness 当前不支持续接历史会话。")
        }

        if let failureDescription = task.failureDescription {
          Label {
            Text(failureDescription)
              .lineLimit(3)
              .truncationMode(.tail)
              .frame(maxWidth: .infinity, alignment: .leading)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
          }
          .font(.caption2)
          .foregroundStyle(.red)
        }
      }
    }
  }
}

struct WorkbenchConversationErrorCard: View {
  let message: String

  var body: some View {
    NativeCard {
      Label {
        Text(message)
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
      }
      .font(.caption)
      .foregroundStyle(.red)
    }
  }
}

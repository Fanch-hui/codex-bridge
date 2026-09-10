import BridgeMCP
import SwiftUI

package struct WorkbenchSessionItem: Identifiable, Sendable {
  package let sessionID: String
  package let providerID: String
  package let providerDisplayName: String
  package let providerSystemImage: String
  package let projectID: String
  package let tasks: [MCPServiceTaskSnapshot]
  package var latestTask: MCPServiceTaskSnapshot { tasks.last ?? tasks[0] }
  package var id: String { [projectID, providerID, sessionID].joined(separator: "\u{1F}") }
  package var turnCount: Int { tasks.count }
  package var isTerminal: Bool { latestTask.isTerminal }
  package var isRunning: Bool { latestTask.isRunning }
  package var status: String { latestTask.status }
  package var title: String {
    let candidate = tasks.first?.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let candidate, !candidate.isEmpty {
      return candidate
    }
    return latestTask.workbenchTitle
  }
}

package struct WorkbenchProviderSessionGroup: Identifiable {
  package let providerID: String
  package let providerDisplayName: String
  package let providerSystemImage: String
  package let sessions: [WorkbenchSessionItem]
  package var id: String { providerID }
}

struct WorkbenchAgentTaskPicker: View {
  @ObservedObject var model: BridgeServiceAppModel
  let tasks: [MCPServiceTaskSnapshot]
  let threads: [MCPThreadSummary]

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
          let groups = WorkbenchAgentTaskPickerContent.groupedSessions(tasks: tasks)
          ForEach(groups) { group in
            Section {
              ForEach(group.sessions) { session in
                Button {
                  model.openSession(session)
                } label: {
                  Label(
                    sessionTitle(session),
                    systemImage: isSessionSelected(session)
                      ? "checkmark" : session.providerSystemImage
                  )
                }
              }
            } header: {
              Label(group.providerDisplayName + " 会话", systemImage: group.providerSystemImage)
            }
          }

          if !orphanThreads.isEmpty {
            Section {
              ForEach(orphanThreads, id: \.threadID) { thread in
                Button {
                  model.openThread(thread.threadID)
                } label: {
                  Label(
                    threadTitle(thread),
                    systemImage: thread.threadID == model.selectedThreadID
                      ? "checkmark" : AgentProviderPresentation.systemImage("codex")
                  )
                }
              }
            } header: {
              Label("Codex 外部历史会话", systemImage: AgentProviderPresentation.systemImage("codex"))
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
    if let session = WorkbenchAgentTaskPickerContent.selectedSession(
      tasks: tasks,
      selectedTaskID: model.selectedTaskID
    ) {
      return "\(session.providerDisplayName) · \(sessionTitle(session, maximumCharacters: 30))"
    }
    if let thread = threads.first(where: { $0.threadID == model.selectedThreadID }) {
      return "Codex · \(threadTitle(thread))"
    }
    return "选择 Agent 会话（\(itemCount)）"
  }

  private var itemCount: Int {
    WorkbenchAgentTaskPickerContent.itemCount(tasks: tasks, threads: threads)
  }

  private var orphanThreads: [MCPThreadSummary] {
    WorkbenchAgentTaskPickerContent.orphanThreads(tasks: tasks, threads: threads)
  }

  private func sessionTitle(
    _ session: WorkbenchSessionItem,
    maximumCharacters: Int = 36
  ) -> String {
    let title = WorkbenchTaskTextPresentation.sessionMenuTitle(
      title: session.title,
      turnCount: session.turnCount,
      maximumCharacters: maximumCharacters
    )
    guard session.projectID != model.selectedProjectID else { return title }
    return "\(model.projectName(for: session.projectID)) · \(title)"
  }

  private func threadTitle(_ thread: MCPThreadSummary) -> String {
    WorkbenchThreadTitlePresentation.compact(
      thread.title ?? thread.preview ?? thread.threadID,
      maximumCharacters: 36
    )
  }
}

package enum WorkbenchAgentTaskPickerContent {
  package static func sessionTasks(
    for task: MCPServiceTaskSnapshot,
    in tasks: [MCPServiceTaskSnapshot]
  ) -> [MCPServiceTaskSnapshot] {
    let sessionID = task.effectiveSessionID ?? task.taskID
    return
      tasks
      .filter {
        $0.projectID == task.projectID
          && $0.providerIdentifier == task.providerIdentifier
          && ($0.effectiveSessionID ?? $0.taskID) == sessionID
      }
      .sorted { $0.updatedAt < $1.updatedAt }
  }

  package static func sessions(
    tasks: [MCPServiceTaskSnapshot]
  ) -> [WorkbenchSessionItem] {
    var grouped: [String: [MCPServiceTaskSnapshot]] = [:]
    var order: [String] = []
    for task in tasks {
      let key = scopedSessionKey(task)
      if grouped[key] == nil {
        order.append(key)
        grouped[key] = []
      }
      grouped[key]?.append(task)
    }
    return order.compactMap { key in
      guard let list = grouped[key], let first = list.first else { return nil }
      let sorted = list.sorted { $0.updatedAt < $1.updatedAt }
      return WorkbenchSessionItem(
        sessionID: first.effectiveSessionID ?? first.taskID,
        providerID: first.providerIdentifier,
        providerDisplayName: first.providerDisplayName,
        providerSystemImage: first.providerSystemImage,
        projectID: first.projectID,
        tasks: sorted
      )
    }
  }

  private static func scopedSessionKey(_ task: MCPServiceTaskSnapshot) -> String {
    [task.projectID, task.providerIdentifier, task.effectiveSessionID ?? task.taskID]
      .joined(separator: "\u{1F}")
  }

  package static func groupedSessions(
    tasks: [MCPServiceTaskSnapshot]
  ) -> [WorkbenchProviderSessionGroup] {
    let allSessions = sessions(tasks: tasks)
    var byProvider: [String: [WorkbenchSessionItem]] = [:]
    for session in allSessions {
      byProvider[session.providerID, default: []].append(session)
    }
    let preferredOrder = ["codex", "antigravity", "opencode", "deepseek-harness"]
    var result: [WorkbenchProviderSessionGroup] = []
    for pid in preferredOrder {
      if let list = byProvider.removeValue(forKey: pid), !list.isEmpty {
        result.append(
          WorkbenchProviderSessionGroup(
            providerID: pid,
            providerDisplayName: AgentProviderPresentation.displayName(pid),
            providerSystemImage: AgentProviderPresentation.systemImage(pid),
            sessions: list
          )
        )
      }
    }
    for (pid, list) in byProvider.sorted(by: { $0.key < $1.key }) where !list.isEmpty {
      result.append(
        WorkbenchProviderSessionGroup(
          providerID: pid,
          providerDisplayName: AgentProviderPresentation.displayName(pid),
          providerSystemImage: AgentProviderPresentation.systemImage(pid),
          sessions: list
        )
      )
    }
    return result
  }

  package static func selectedSession(
    tasks: [MCPServiceTaskSnapshot],
    selectedTaskID: String?
  ) -> WorkbenchSessionItem? {
    guard let selectedTaskID else { return nil }
    let allSessions = sessions(tasks: tasks)
    return allSessions.first(where: { session in
      session.tasks.contains(where: { $0.taskID == selectedTaskID })
    })
  }

  package static func selectedTask(
    tasks: [MCPServiceTaskSnapshot],
    selectedTaskID: String?
  ) -> MCPServiceTaskSnapshot? {
    guard let selectedTaskID else { return nil }
    return tasks.first(where: { $0.taskID == selectedTaskID })
  }

  package static func orphanThreads(
    tasks: [MCPServiceTaskSnapshot],
    threads: [MCPThreadSummary]
  ) -> [MCPThreadSummary] {
    let taskThreadIDs = Set(
      tasks.compactMap { task in
        task.isCodexTask ? task.threadID : nil
      })
    return threads.filter { !taskThreadIDs.contains($0.threadID) }
  }

  package static func itemCount(
    tasks: [MCPServiceTaskSnapshot],
    threads: [MCPThreadSummary]
  ) -> Int {
    sessions(tasks: tasks).count + orphanThreads(tasks: tasks, threads: threads).count
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

package enum WorkbenchTaskTextPresentation {
  package static func sessionMenuTitle(
    title: String,
    turnCount: Int,
    maximumCharacters: Int = 36
  ) -> String {
    let cleaned = cleanTitle(title, maximumCharacters: maximumCharacters) ?? "未命名会话"
    if turnCount > 1 {
      return "\(cleaned) [\(turnCount)轮]"
    }
    return cleaned
  }

  package static func menuTitle(
    for task: MCPServiceTaskSnapshot,
    maximumCharacters: Int = 36
  ) -> String {
    let title = cleanTitle(task.workbenchTitle, maximumCharacters: maximumCharacters) ?? "未命名任务"
    return "\(task.providerDisplayName) · \(title)"
  }

  package static func cleanTitle(_ value: String?, maximumCharacters: Int = 36) -> String? {
    guard let value else { return nil }
    var raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.contains("could not run native tool") {
      if let toolRange = raw.range(of: "tool '") {
        let after = raw[toolRange.upperBound...]
        if let endRange = after.range(of: "'") {
          let toolName = after[..<endRange.lowerBound]
          raw = "工具 \(toolName) 执行异常"
        } else {
          raw = "工具执行异常"
        }
      } else {
        raw = "工具执行异常"
      }
    } else if raw.contains("denied this provider invocation") {
      raw = "用户拒绝执行"
    }
    return compact(raw, maximumCharacters: maximumCharacters)
  }

  package static func cardTitle(for task: MCPServiceTaskSnapshot) -> String? {
    compact(task.currentStep ?? task.resultSummary, maximumCharacters: 240)
  }

  private static func compact(_ value: String?, maximumCharacters: Int) -> String? {
    guard let value else { return nil }
    let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !normalized.isEmpty else { return nil }
    guard normalized.count > maximumCharacters else { return normalized }
    return String(normalized.prefix(maximumCharacters - 1)) + "…"
  }
}

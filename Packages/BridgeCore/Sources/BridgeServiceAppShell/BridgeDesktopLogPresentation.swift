import BridgeDesktopUI
import BridgeMCP
import Foundation

@MainActor
enum BridgeDesktopLogPresentation {
  static let kindOptions = [
    BridgeDesktopChoice(id: "all", title: "全部"),
    BridgeDesktopChoice(id: "command", title: "命令"),
    BridgeDesktopChoice(id: "file", title: "文件"),
    BridgeDesktopChoice(id: "other", title: "其他"),
  ]

  static func rows(from model: BridgeServiceAppModel) -> [BridgeDesktopLogRow] {
    let query = model.desktopLogSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return model.tasks
      .flatMap { task in
        task.recentEvents.compactMap { event in
          let category = category(for: event.kind)
          guard
            matches(
              task: task,
              event: event,
              category: category,
              projectID: model.desktopLogProjectID,
              kind: model.desktopLogKind,
              query: query,
              model: model
            )
          else { return nil }
          return BridgeDesktopLogRow(
            id: "\(task.taskID)-\(event.sequence)",
            sequence: event.sequence,
            taskID: task.taskID,
            projectID: task.projectID,
            projectName: model.projectName(for: task.projectID),
            kind: category,
            kindLabel: label(for: category),
            summary: event.summary,
            timestamp: event.occurredAt
          )
        }
      }
      .sorted { lhs, rhs in
        if lhs.sequence != rhs.sequence { return lhs.sequence > rhs.sequence }
        return lhs.id > rhs.id
      }
  }

  static func copyText(rows: [BridgeDesktopLogRow]) -> String {
    rows.map {
      "#\($0.sequence) [\($0.projectName)] [\($0.kindLabel)] \($0.summary) (\($0.timestamp))"
    }.joined(separator: "\n")
  }

  static func category(for rawKind: String) -> String {
    switch rawKind {
    case "execution.command_completed":
      return "command"
    case "execution.file_changed":
      return "file"
    default:
      return "other"
    }
  }

  static func label(for category: String) -> String {
    switch category {
    case "command": return "命令"
    case "file": return "文件"
    default: return "其他"
    }
  }

  private static func matches(
    task: MCPServiceTaskSnapshot,
    event: MCPServiceTaskEvent,
    category: String,
    projectID: String?,
    kind: String,
    query: String,
    model: BridgeServiceAppModel
  ) -> Bool {
    guard projectID == nil || projectID == task.projectID else { return false }
    guard kind == "all" || kind == category else { return false }
    guard !query.isEmpty else { return true }
    let projectName = model.projectName(for: task.projectID).lowercased()
    return event.summary.lowercased().contains(query)
      || event.kind.lowercased().contains(query)
      || projectName.contains(query)
  }
}

extension BridgeDesktopUIStateBuilder {
  static func logs(from model: BridgeServiceAppModel) -> BridgeDesktopLogsState {
    let rows = BridgeDesktopLogPresentation.rows(from: model)
    let selectedRow = rows.first { $0.id == model.desktopSelectedLogID }
    return BridgeDesktopLogsState(
      header: BridgeDesktopPageHeader(
        title: "日志",
        subtitle: "查看 Service 记录的真实任务事件，并按项目、类型和摘要筛选。",
        symbol: BridgeServiceNavigation.logs.symbol
      ),
      searchText: model.desktopLogSearchText,
      projectOptions: [BridgeDesktopChoice(id: "all", title: "全部项目")]
        + model.projects.map { BridgeDesktopChoice(id: $0.projectID, title: $0.name) },
      selectedProjectID: model.desktopLogProjectID,
      kindOptions: BridgeDesktopLogPresentation.kindOptions,
      selectedKind: model.desktopLogKind,
      rows: rows,
      selectedRowID: model.desktopSelectedLogID,
      detailText: selectedRow.map(logDetail),
      canCopy: !rows.isEmpty,
      canRefresh: !model.isRefreshing
    )
  }

  private static func logDetail(_ row: BridgeDesktopLogRow) -> String {
    [
      "任务：\(row.taskID)",
      "项目：\(row.projectName)",
      "类型：\(row.kindLabel)（\(row.kind)）",
      "序号：\(row.sequence)",
      "时间：\(row.timestamp)",
      "摘要：\(row.summary)",
    ].joined(separator: "\n")
  }
}

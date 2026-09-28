import BridgeMCP

public enum TaskLogPresentation {
  public struct Item: Equatable, Sendable {
    public let id: String
    public let rowText: String
    public let detailText: String
    public let sequence: Int64

    public init(id: String, rowText: String, detailText: String, sequence: Int64) {
      self.id = id
      self.rowText = rowText
      self.detailText = detailText
      self.sequence = sequence
    }
  }

  public static func flatten(
    tasks: [MCPServiceTaskSnapshot],
    projectNames: [String: String]
  ) -> [Item] {
    tasks.flatMap { task in
      task.recentEvents.map { event in
        let project = projectNames[task.projectID] ?? task.projectID
        let kind = kindLabel(kind: event.kind, summary: event.summary)
        let detail = [
          "序号：#\(event.sequence)",
          "项目：\(project)",
          "任务：\(task.taskID)",
          "类型：\(kind)",
          "时间：\(event.occurredAt)",
          "摘要：\(event.summary)",
        ].joined(separator: "\r\n")
        return Item(
          id: "\(task.taskID)_\(event.sequence)",
          rowText: "#\(event.sequence) · \(project) · \(kind) · \(event.summary)",
          detailText: detail,
          sequence: event.sequence
        )
      }
    }
    .sorted { $0.sequence > $1.sequence }
  }

  private static func kindLabel(kind: String, summary: String) -> String {
    let value = "\(kind) \(summary)".lowercased()
    if value.contains("command") || value.contains("exec") || value.contains("run") {
      return "命令"
    }
    if value.contains("file") || value.contains("edit") || value.contains("write") {
      return "文件"
    }
    if value.contains("failed") || value.contains("error") {
      return "错误"
    }
    return "事件"
  }
}

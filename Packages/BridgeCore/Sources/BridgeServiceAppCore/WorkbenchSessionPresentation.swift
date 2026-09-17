import BridgeMCP
import Foundation

public struct WorkbenchSessionItem: Identifiable, Equatable, Sendable {
  public let sessionID: String
  public let providerID: String
  public let providerDisplayName: String
  public let providerSystemImage: String
  public let projectID: String
  public let tasks: [MCPServiceTaskSnapshot]

  public var latestTask: MCPServiceTaskSnapshot { tasks.last ?? tasks[0] }
  public var id: String { [projectID, providerID, sessionID].joined(separator: "\u{1F}") }
  public var turnCount: Int { tasks.count }
  public var isTerminal: Bool { latestTask.isTerminal }
  public var isRunning: Bool { latestTask.isRunning }
  public var status: String { latestTask.status }
  public var title: String {
    if let firstPrompt = tasks.first?.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
      !firstPrompt.isEmpty
    {
      return firstPrompt
    }
    return latestTask.workbenchTitle
  }

  public init(
    sessionID: String,
    providerID: String,
    providerDisplayName: String,
    providerSystemImage: String,
    projectID: String,
    tasks: [MCPServiceTaskSnapshot]
  ) {
    precondition(!tasks.isEmpty)
    self.sessionID = sessionID
    self.providerID = providerID
    self.providerDisplayName = providerDisplayName
    self.providerSystemImage = providerSystemImage
    self.projectID = projectID
    self.tasks = tasks
  }
}

public struct WorkbenchProviderSessionGroup: Identifiable, Equatable, Sendable {
  public let providerID: String
  public let providerDisplayName: String
  public let providerSystemImage: String
  public let sessions: [WorkbenchSessionItem]

  public var id: String { providerID }
}

public enum WorkbenchSessionCatalog {
  public static func sessionTasks(
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

  public static func sessions(
    tasks: [MCPServiceTaskSnapshot]
  ) -> [WorkbenchSessionItem] {
    var grouped: [String: [MCPServiceTaskSnapshot]] = [:]
    var orderedKeys: [String] = []
    for task in tasks {
      let key = scopedSessionKey(task)
      if grouped[key] == nil {
        grouped[key] = []
        orderedKeys.append(key)
      }
      grouped[key]?.append(task)
    }
    return orderedKeys.compactMap { key in
      guard let values = grouped[key], let first = values.first else { return nil }
      let sorted = values.sorted { $0.updatedAt < $1.updatedAt }
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

  public static func groupedSessions(
    tasks: [MCPServiceTaskSnapshot]
  ) -> [WorkbenchProviderSessionGroup] {
    let sessions = sessions(tasks: tasks)
    var byProvider: [String: [WorkbenchSessionItem]] = [:]
    for session in sessions {
      byProvider[session.providerID, default: []].append(session)
    }
    let preferredOrder = ["codex", "antigravity", "opencode", "deepseek-harness"]
    var result: [WorkbenchProviderSessionGroup] = []
    for providerID in preferredOrder {
      guard let values = byProvider.removeValue(forKey: providerID), !values.isEmpty else {
        continue
      }
      result.append(group(providerID: providerID, sessions: values))
    }
    for (providerID, values) in byProvider.sorted(by: { $0.key < $1.key }) where !values.isEmpty {
      result.append(group(providerID: providerID, sessions: values))
    }
    return result
  }

  public static func selectedSession(
    tasks: [MCPServiceTaskSnapshot],
    selectedTaskID: String?
  ) -> WorkbenchSessionItem? {
    guard let selectedTaskID else { return nil }
    return sessions(tasks: tasks).first { session in
      session.tasks.contains(where: { $0.taskID == selectedTaskID })
    }
  }

  public static func selectedTask(
    tasks: [MCPServiceTaskSnapshot],
    selectedTaskID: String?
  ) -> MCPServiceTaskSnapshot? {
    guard let selectedTaskID else { return nil }
    return tasks.first { $0.taskID == selectedTaskID }
  }

  public static func orphanThreads(
    tasks: [MCPServiceTaskSnapshot],
    threads: [MCPThreadSummary]
  ) -> [MCPThreadSummary] {
    let taskThreadIDs = Set(tasks.compactMap { $0.isCodexTask ? $0.threadID : nil })
    return threads.filter { !taskThreadIDs.contains($0.threadID) }
  }

  public static func itemCount(
    tasks: [MCPServiceTaskSnapshot],
    threads: [MCPThreadSummary]
  ) -> Int {
    sessions(tasks: tasks).count + orphanThreads(tasks: tasks, threads: threads).count
  }

  private static func scopedSessionKey(_ task: MCPServiceTaskSnapshot) -> String {
    [task.projectID, task.providerIdentifier, task.effectiveSessionID ?? task.taskID]
      .joined(separator: "\u{1F}")
  }

  private static func group(
    providerID: String,
    sessions: [WorkbenchSessionItem]
  ) -> WorkbenchProviderSessionGroup {
    WorkbenchProviderSessionGroup(
      providerID: providerID,
      providerDisplayName: AgentProviderPresentation.displayName(providerID),
      providerSystemImage: AgentProviderPresentation.systemImage(providerID),
      sessions: sessions.sorted { $0.latestTask.updatedAt > $1.latestTask.updatedAt }
    )
  }
}

public enum WorkbenchTaskTextPresentation {
  public static func sessionMenuTitle(
    title: String,
    turnCount: Int,
    maximumCharacters: Int = 36
  ) -> String {
    let cleaned = cleanTitle(title, maximumCharacters: maximumCharacters) ?? "未命名会话"
    return turnCount > 1 ? "\(cleaned) [\(turnCount)轮]" : cleaned
  }

  public static func menuTitle(
    for task: MCPServiceTaskSnapshot,
    maximumCharacters: Int = 36
  ) -> String {
    let title = cleanTitle(task.workbenchTitle, maximumCharacters: maximumCharacters) ?? "未命名任务"
    return "\(task.providerDisplayName) · \(title)"
  }

  public static func cleanTitle(
    _ value: String?,
    maximumCharacters: Int = 36
  ) -> String? {
    guard let value else { return nil }
    var raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.contains("could not run native tool") {
      if let start = raw.range(of: "tool '") {
        let suffix = raw[start.upperBound...]
        raw =
          suffix.range(of: "'").map { "工具 \(suffix[..<$0.lowerBound]) 执行异常" }
          ?? "工具执行异常"
      } else {
        raw = "工具执行异常"
      }
    } else if raw.contains("denied this provider invocation") {
      raw = "用户拒绝执行"
    }
    return compact(raw, maximumCharacters: maximumCharacters)
  }

  public static func cardTitle(for task: MCPServiceTaskSnapshot) -> String? {
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

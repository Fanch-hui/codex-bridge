import BridgeAgentCore
import BridgeDomain
import BridgeSecurity
import BridgeServiceCore
import Foundation

struct ServiceExecutionAgentEventProcessor: Sendable {
  private let tasks: ServiceTaskManager
  private let projects: ServiceProjectService
  private let conversation: TaskConversationBuffer

  init(
    tasks: ServiceTaskManager,
    projects: ServiceProjectService,
    conversation: TaskConversationBuffer
  ) {
    self.tasks = tasks
    self.projects = projects
    self.conversation = conversation
  }

  func process(
    _ event: AgentEvent,
    taskID: TaskID
  ) async throws {
    switch event {
    case .content(let update):
      guard update.role == .assistant else { return }
      let kind: ServiceTaskMessageKind = update.kind == .reasoning ? .reasoning : .agent
      let bufferKey = Self.conversationPrefix(kind) + Self.agentItemKey(update.key)
      switch update.mode {
      case .delta:
        await conversation.appendDelta(
          taskID: taskID,
          itemID: Self.agentItemKey(update.key),
          delta: update.content,
          kind: kind
        )
      case .full:
        await conversation.upsertAuthoritativeEntry(
          taskID: taskID,
          key: bufferKey,
          kind: kind,
          content: update.content,
          isFinal: update.isFinal
        )
      }

    case .steerDispatched(let text):
      await conversation.appendUserMessage(taskID: taskID, content: text)

    case .tool(let update):
      let itemID = Self.agentToolItemID(update.key)
      let arguments = update.arguments.map {
        OutboundContentSecurity.redactedToolArguments($0, maximumUTF8Bytes: 64 * 1_024)
      }
      await conversation.upsertToolCall(
        taskID: taskID,
        call: try ExecutionToolCall(
          itemID: itemID,
          tool: update.name.isEmpty ? "tool" : update.name,
          arguments: arguments,
          status: Self.toolStatus(update.status),
          childRuns: update.childRuns
        ),
        output: update.output.map {
          OutboundContentSecurity.redactedCommandOutput($0, maximumUTF8Bytes: 256 * 1_024)
        }
      )
      if update.status == .completed, Self.isEditTool(update) {
        let paths = try await agentChangedPaths(update.locations, taskID: taskID)
        if !paths.isEmpty {
          _ = try await tasks.recordChangedFiles(
            taskID: taskID,
            relativePaths: paths,
            summary: "The agent completed file changes."
          )
        }
      }

    case .plan(let entries):
      let step =
        entries.first(where: { $0.status == "in_progress" })?.content
        ?? entries.first(where: { $0.status == nil || $0.status == "pending" })?.content
        ?? entries.last?.content
      if let currentStep = step.map(Self.boundedPlanStep) {
        _ = try await tasks.updatePlan(taskID: taskID, currentStep: currentStep)
      }

    case .usage(let value):
      try await tasks.recordUsage(
        AgentUsageStatistics(
          contextTokens: value.usedTokens, contextWindow: value.contextSize,
          costAmount: value.costAmount, currency: value.currency), taskID: taskID)

    case .usageStatistics(let value):
      try await tasks.recordUsage(value, taskID: taskID)

    case .approvalRequested:
      return

    case .userInputRequested:
      return

    case .approvalAutomaticallyDenied(let itemID):
      await conversation.declineToolCall(
        taskID: taskID,
        itemID: itemID,
        fallbackContent: "The requested operation was denied by local policy."
      )
      return

    case .completed:
      return

    case .interrupted:
      return

    case .failed:
      return
    }
  }

  private static func isEditTool(_ update: AgentToolUpdate) -> Bool {
    let values = [update.name, update.title, update.kind]
      .compactMap { $0?.lowercased() }
    return values.contains { value in
      value == "file_change"
        || value.contains("edit")
        || value.contains("write")
        || value.contains("patch")
    }
  }

  private func agentChangedPaths(_ locations: [String], taskID: TaskID) async throws -> [String] {
    guard !locations.isEmpty,
      let task = try await tasks.task(id: taskID),
      let project = try await projects.project(id: task.projectID)
    else {
      return []
    }
    let paths = locations.compactMap { location in
      try? ExecutionValidation.relativePath(location, root: project.root.canonicalPath)
    }
    return Array(Set(paths)).sorted()
  }

  private static func conversationPrefix(_ kind: ServiceTaskMessageKind) -> String {
    switch kind {
    case .reasoning: "reasoning:"
    default: "agent:"
    }
  }

  /// Keep the provider stream key stable when a provider includes a buffer prefix.
  private static func agentItemKey(_ key: String) -> String {
    var trimmed = Substring(key)
    for candidate in ["agent:", "reasoning:", "tool:", "user:"] where trimmed.hasPrefix(candidate) {
      trimmed = trimmed.dropFirst(candidate.count)
    }
    return trimmed.count > 256 ? String(trimmed.prefix(256)) : String(trimmed)
  }

  private static func agentToolItemID(_ key: String) -> String {
    key.hasPrefix("tool:") ? String(key.dropFirst("tool:".count)) : key
  }

  private static func toolStatus(_ status: AgentToolStatus) -> ExecutionToolCallStatus {
    switch status {
    case .pending, .inProgress: .inProgress
    case .completed: .completed
    case .failed: .failed
    case .cancelled: .cancelled
    case .declined: .declined
    }
  }

  private static func boundedPlanStep(_ content: String) -> String {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.utf8.count > 512 else { return trimmed }
    return String(decoding: trimmed.utf8.prefix(512), as: UTF8.self)
  }
}

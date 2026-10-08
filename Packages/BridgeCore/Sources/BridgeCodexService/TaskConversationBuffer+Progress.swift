import BridgeAgentCore
import BridgeDomain
import BridgeServiceCore
import Foundation

extension TaskConversationBuffer {
  func mergeDelta(
    taskID: TaskID,
    key: String,
    delta: String,
    kind: ServiceTaskMessageKind,
    in state: TaskState
  ) -> ConversationChange? {
    if let index = state.index[key], state.entries.indices.contains(index) {
      let entry = state.entries[index]
      guard !entry.isFinal, !state.omittedContentKeys.contains(key) else { return nil }
      let combined = entry.content + delta
      let content = Self.boundedProgress(combined)
      let omitted = content != combined
      if omitted { state.omittedContentKeys.insert(key) }
      guard content != entry.content else { return nil }
      state.entries[index] = Entry(
        key: entry.key,
        role: .agent,
        kind: kind,
        content: content,
        isFinal: false,
        createdAt: entry.createdAt,
        updatedAt: Date()
      )
      return ConversationChange(
        taskID: taskID,
        key: entry.key,
        role: .agent,
        kind: kind,
        delta: omitted ? nil : delta,
        baseContentLength: omitted ? 0 : entry.content.count,
        fullContent: omitted ? content : nil,
        final: false
      )
    }

    let content = Self.boundedProgress(delta)
    if content != delta { state.omittedContentKeys.insert(key) }
    append(
      Entry(key: key, role: .agent, kind: kind, content: content, isFinal: false),
      in: state
    )
    return ConversationChange(
      taskID: taskID,
      key: key,
      role: .agent,
      kind: kind,
      delta: nil,
      baseContentLength: 0,
      fullContent: content,
      final: false
    )
  }

  func mergeToolCallProgress(
    taskID: TaskID,
    key: String,
    progress: String,
    in state: TaskState
  ) -> ConversationChange? {
    guard let index = state.index[key], state.entries.indices.contains(index) else { return nil }
    let existing = state.entries[index]
    guard !existing.isFinal, !state.omittedContentKeys.contains(key) else { return nil }
    let line = existing.content.isEmpty ? progress : "\n" + progress
    let combined = existing.content + line
    let content = Self.boundedProgress(combined)
    let omitted = content != combined
    if omitted { state.omittedContentKeys.insert(key) }
    guard content != existing.content else { return nil }
    state.entries[index] = Entry(
      key: key,
      role: .agent,
      kind: .toolCall,
      content: content,
      toolName: existing.toolName,
      toolStatus: existing.toolStatus,
      toolArguments: existing.toolArguments,
      isFinal: false,
      createdAt: existing.createdAt,
      updatedAt: Date()
    )
    return ConversationChange(
      taskID: taskID,
      key: key,
      role: .agent,
      kind: .toolCall,
      delta: omitted ? nil : line,
      baseContentLength: omitted ? 0 : existing.content.count,
      fullContent: omitted ? content : nil,
      final: false,
      toolName: existing.toolName,
      toolStatus: existing.toolStatus,
      toolArguments: existing.toolArguments
    )
  }

  private static func boundedProgress(_ content: String) -> String {
    AgentProgressText.bounded(content, maximumBytes: AgentProgressText.maximumContentBytes)
  }
}

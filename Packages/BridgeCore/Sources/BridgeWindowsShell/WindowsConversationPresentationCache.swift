#if os(Windows)
  import BridgeDesktopUI
  import BridgeServiceAppCore
  import Foundation

  /// Stores already converted conversation entries for the active task.
  /// Streaming updates usually replace the last entry, so unchanged history
  /// remains a value reused from the previous presentation.
  struct WindowsConversationPresentationCache {
    private var taskID: String?
    private var providerID: String?
    private var sourceEntries: [TaskConversationModel.Entry] = []
    private var presentations: [BridgeDesktopConversationEntry] = []
    private var legacyTexts: [String] = []

    mutating func update(
      taskID: String,
      providerID: String,
      entries: [TaskConversationModel.Entry]
    ) -> [BridgeDesktopConversationEntry] {
      if self.taskID != taskID || self.providerID != providerID {
        self.taskID = taskID
        self.providerID = providerID
        sourceEntries = entries
        presentations = entries.map {
          WindowsConversationEntryPresenter.make($0, providerID: providerID)
        }
        legacyTexts = entries.map(WindowsConversationEntryPresenter.legacyText)
        return presentations
      }

      guard !entries.isEmpty else {
        sourceEntries.removeAll(keepingCapacity: true)
        presentations.removeAll(keepingCapacity: true)
        legacyTexts.removeAll(keepingCapacity: true)
        return presentations
      }

      if entries.count >= sourceEntries.count,
        Self.hasSameKeys(sourceEntries, entries)
      {
        var next = presentations
        var nextLegacyTexts = legacyTexts
        for index in sourceEntries.indices where sourceEntries[index] != entries[index] {
          next[index] = WindowsConversationEntryPresenter.make(
            entries[index], providerID: providerID
          )
          nextLegacyTexts[index] = WindowsConversationEntryPresenter.legacyText(entries[index])
        }
        if entries.count > sourceEntries.count {
          next.append(
            contentsOf: entries.dropFirst(sourceEntries.count).map {
              WindowsConversationEntryPresenter.make($0, providerID: providerID)
            })
          nextLegacyTexts.append(
            contentsOf: entries.dropFirst(sourceEntries.count).map(
              WindowsConversationEntryPresenter.legacyText
            ))
        }
        sourceEntries = entries
        presentations = next
        legacyTexts = nextLegacyTexts
        return next
      }

      sourceEntries = entries
      presentations = entries.map {
        WindowsConversationEntryPresenter.make($0, providerID: providerID)
      }
      legacyTexts = entries.map(WindowsConversationEntryPresenter.legacyText)
      return presentations
    }

    func text(isStreaming: Bool, errorMessage: String?) -> String {
      var text: String
      if sourceEntries.isEmpty {
        text = isStreaming ? "等待 Provider 输出…" : "暂无对话记录。"
      } else {
        text = legacyTexts.joined(separator: "\r\n\r\n")
      }
      if let error = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
        text += "\r\n\r\n[错误] \(error)"
      }
      return text
    }

    mutating func reset() {
      taskID = nil
      providerID = nil
      sourceEntries.removeAll(keepingCapacity: false)
      presentations.removeAll(keepingCapacity: false)
      legacyTexts.removeAll(keepingCapacity: false)
    }

    private static func hasSameKeys(
      _ old: [TaskConversationModel.Entry],
      _ new: [TaskConversationModel.Entry]
    ) -> Bool {
      guard new.count >= old.count else { return false }
      for index in old.indices where old[index].key != new[index].key {
        return false
      }
      return true
    }
  }

  enum WindowsConversationEntryPresenter {
    static func legacyText(_ entry: TaskConversationModel.Entry) -> String {
      let role = entry.role == "user" ? "用户" : "Agent"
      var content = entry.displayContent.trimmingCharacters(in: .whitespacesAndNewlines)
      if let toolName = nonEmpty(entry.toolName) {
        let tool = nonEmpty(entry.toolStatus).map { "\(toolName)（\($0)）" } ?? toolName
        let prefix = "[工具：\(tool)]"
        content = content.isEmpty ? prefix : "\(prefix)\r\n\(content)"
      }
      return "\(role)：\(content)"
    }

    static func make(
      _ entry: TaskConversationModel.Entry,
      providerID: String
    ) -> BridgeDesktopConversationEntry {
      let role =
        entry.role == "user"
        ? "用户" : AgentProviderPresentation.displayName(providerID)
      if entry.kind == "reasoning" {
        return BridgeDesktopConversationEntry(
          id: entry.key,
          role: role,
          text: entry.content,
          kind: entry.kind,
          displayTitle: CodexTranscriptPresentation.reasoningTitle(
            providerID: providerID,
            streaming: !entry.isFinal
          ),
          displayStatus: entry.isFinal ? "" : "进行中",
          symbol: "brain.head.profile",
          isFinal: entry.isFinal,
          status: entry.isFinal ? "final" : "streaming"
        )
      }
      if entry.kind == "tool_call" {
        let displayContent = entry.displayContent
        let toolStatus = CodexTranscriptPresentation.resolvedToolStatus(
          providerID: providerID, name: entry.toolName, status: entry.toolStatus,
          output: displayContent
        )
        let presentation = CodexTranscriptPresentation.tool(
          providerID: providerID,
          name: entry.toolName,
          status: entry.toolStatus
        )
        return BridgeDesktopConversationEntry(
          id: entry.key,
          role: role,
          text: displayContent,
          kind: entry.kind,
          toolName: entry.toolName,
          toolStatus: toolStatus,
          toolArguments: entry.toolArguments,
          displayTitle: presentation.title,
          displayStatus: CodexTranscriptPresentation.statusLabel(toolStatus),
          symbol: presentation.systemImage,
          isFinal: entry.isFinal,
          status: entry.isFinal ? "final" : "streaming"
        )
      }
      return BridgeDesktopConversationEntry(
        id: entry.key,
        role: role,
        text: entry.content,
        kind: entry.kind,
        isFinal: entry.isFinal,
        status: entry.isFinal ? "final" : "streaming"
      )
    }

    private static func nonEmpty(_ value: String?) -> String? {
      guard let value else { return nil }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
  }
#endif

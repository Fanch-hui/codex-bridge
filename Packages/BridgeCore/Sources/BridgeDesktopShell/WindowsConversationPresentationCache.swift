#if os(Windows) || os(Linux)
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
        return presentations
      }

      guard !entries.isEmpty else {
        sourceEntries.removeAll(keepingCapacity: true)
        presentations.removeAll(keepingCapacity: true)
        return presentations
      }

      let updatePlan = TaskConversationPresentationUpdatePlan(
        previous: sourceEntries,
        next: entries
      )
      if !updatePlan.needsFullRebuild {
        var next = presentations
        for index in updatePlan.changedEntryIndices {
          next[index] = WindowsConversationEntryPresenter.make(
            entries[index], providerID: providerID
          )
        }
        if let appendedRange = updatePlan.appendedEntryRange {
          next.append(
            contentsOf: entries[appendedRange].map {
              WindowsConversationEntryPresenter.make($0, providerID: providerID)
            })
        }
        sourceEntries = entries
        presentations = next
        return next
      }

      sourceEntries = entries
      presentations = entries.map {
        WindowsConversationEntryPresenter.make($0, providerID: providerID)
      }
      return presentations
    }

    mutating func reset() {
      taskID = nil
      providerID = nil
      sourceEntries.removeAll(keepingCapacity: false)
      presentations.removeAll(keepingCapacity: false)
    }
  }

  enum WindowsConversationEntryPresenter {
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
  }
#endif

import BridgeDesktopUI
import BridgeServiceAppCore

/// Reuses rendered conversation entries across macOS state projections.
/// Streaming usually changes only the last entry, so historical Markdown is
/// not parsed again for every token batch.
@MainActor
struct BridgeDesktopConversationPresentationCache {
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
        BridgeDesktopUIStateBuilder.conversationEntry($0, providerID: providerID)
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
    guard !updatePlan.needsFullRebuild else {
      sourceEntries = entries
      presentations = entries.map {
        BridgeDesktopUIStateBuilder.conversationEntry($0, providerID: providerID)
      }
      return presentations
    }

    var next = presentations
    for index in updatePlan.changedEntryIndices {
      next[index] = BridgeDesktopUIStateBuilder.conversationEntry(
        entries[index], providerID: providerID
      )
    }
    if let appendedRange = updatePlan.appendedEntryRange {
      next.append(
        contentsOf: entries[appendedRange].map {
          BridgeDesktopUIStateBuilder.conversationEntry($0, providerID: providerID)
        }
      )
    }
    sourceEntries = entries
    presentations = next
    return next
  }

  mutating func reset() {
    taskID = nil
    providerID = nil
    sourceEntries.removeAll(keepingCapacity: false)
    presentations.removeAll(keepingCapacity: false)
  }
}

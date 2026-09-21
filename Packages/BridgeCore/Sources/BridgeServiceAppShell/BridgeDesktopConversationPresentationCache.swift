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

    guard entries.count >= sourceEntries.count, Self.hasSameKeys(sourceEntries, entries) else {
      sourceEntries = entries
      presentations = entries.map {
        BridgeDesktopUIStateBuilder.conversationEntry($0, providerID: providerID)
      }
      return presentations
    }

    var next = presentations
    for index in sourceEntries.indices where sourceEntries[index] != entries[index] {
      next[index] = BridgeDesktopUIStateBuilder.conversationEntry(
        entries[index], providerID: providerID
      )
    }
    if entries.count > sourceEntries.count {
      next.append(
        contentsOf: entries.dropFirst(sourceEntries.count).map {
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

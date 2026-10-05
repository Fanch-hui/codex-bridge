import BridgeDomain
import Foundation

extension TaskConversationBuffer {
  func flush(taskID: TaskID) async -> Bool {
    guard let state = states[taskID] else { return true }
    guard !state.isFlushing else { return false }
    let revisions = state.dirtyRevisions
    // Closing retries dirty entries without rewriting clean persisted messages.
    let snapshot: [(Entry, Int?)] = state.entries.compactMap { entry in
      guard let revision = revisions[entry.key] else { return nil }
      return (entry, Optional(revision))
    }
    guard !snapshot.isEmpty else { return true }

    state.isFlushing = true
    let flushedDeltaCount = state.unflushedCount
    var persisted: [(String, Int?)] = []
    for (entry, revision) in snapshot {
      do {
        let record = try await tasks.upsertTaskMessage(
          taskID: taskID,
          key: entry.key,
          role: entry.role,
          content: entry.content,
          kind: entry.kind,
          toolName: entry.toolName,
          toolStatus: entry.toolStatus,
          toolArguments: entry.toolArguments,
          createdAt: entry.createdAt,
          updatedAt: entry.updatedAt
        )
        persisted.append((entry.key, revision))
        if state.dirtyRevisions[entry.key] == revision,
          let position = state.index[entry.key]
        {
          state.entries[position].messageID = record.id
          notify(
            ConversationChange(
              taskID: taskID, key: entry.key, role: entry.role, kind: entry.kind,
              delta: nil, baseContentLength: 0, fullContent: nil, final: false,
              messageID: record.id
            ), in: state
          )
        }
      } catch {
        continue
      }
    }

    for (key, revision) in persisted {
      state.persistedKeys.insert(key)
      guard let revision, state.dirtyRevisions[key] == revision else { continue }
      state.dirtyRevisions.removeValue(forKey: key)
    }
    state.unflushedCount = max(
      state.dirtyRevisions.count,
      state.unflushedCount - flushedDeltaCount
    )
    state.lastFlush = Date()
    state.isFlushing = false
    prunePersistedFinalEntries(in: state)
    return persisted.count == snapshot.count
  }

  private func prunePersistedFinalEntries(in state: TaskState) {
    var excess = state.entries.count - Self.maximumRetainedMessagesPerTask
    guard excess > 0 else { return }
    var retained: [Entry] = []
    retained.reserveCapacity(state.entries.count - excess)
    for entry in state.entries {
      let canEvict =
        excess > 0
        && entry.isFinal
        && state.persistedKeys.contains(entry.key)
        && state.dirtyRevisions[entry.key] == nil
      if canEvict {
        excess -= 1
        state.persistedKeys.remove(entry.key)
      } else {
        retained.append(entry)
      }
    }
    guard retained.count != state.entries.count else { return }
    state.entries = retained
    rebuildIndex(in: state)
  }

  private func rebuildIndex(in state: TaskState) {
    state.index.removeAll(keepingCapacity: true)
    for (position, entry) in state.entries.enumerated() {
      state.index[entry.key] = position
    }
  }

}

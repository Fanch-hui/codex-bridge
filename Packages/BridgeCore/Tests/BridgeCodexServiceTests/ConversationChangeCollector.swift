import BridgeCodexService

actor ChangeCollector {
  private var changes: [ConversationChange] = []

  func collect(_ stream: AsyncStream<ConversationChange>) async {
    for await change in stream {
      changes.append(change)
    }
  }

  func count() -> Int {
    changes.count
  }

  func count(key: String) -> Int {
    changes.count { $0.key == key }
  }

  func first() -> ConversationChange? {
    changes.first
  }

  func all() -> [ConversationChange] {
    changes
  }
}

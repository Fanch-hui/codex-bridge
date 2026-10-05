import BridgeIPC

extension TaskConversationModel {
  func trimOversizedCurrentTaskEntries() {
    guard !isBrowsingHistory,
      let range = TaskConversationWindowPolicy.currentTaskTrimRange(
        priorEntryCount: priorEntries.count,
        entries: entries,
        maximum: Self.maximumCurrentTaskEntries
      )
    else { return }
    entries.removeSubrange(range)
    canLoadEarlierCurrentTask = true
    rebuildIndex()
    updateEarlierAvailability()
  }
}

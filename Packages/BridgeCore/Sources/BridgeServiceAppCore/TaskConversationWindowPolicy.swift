public enum TaskConversationWindowPolicy {
  public static let defaultMaximumCurrentTaskEntries = 400

  public static func currentTaskTrimRange(
    priorEntryCount: Int,
    entries: [TaskConversationModel.Entry],
    maximum: Int
  ) -> Range<Int>? {
    let currentEntryCount = entries.count - priorEntryCount
    guard maximum > 0, priorEntryCount >= 0, currentEntryCount > maximum else {
      return nil
    }
    let firstRetainedIndex = entries.count - maximum
    // A message without an acknowledged database ID may contain unsaved output.
    // Keep it, and retain a persisted anchor before it for history pagination.
    let firstUnsavedIndex =
      entries[priorEntryCount..<firstRetainedIndex]
      .firstIndex(where: { $0.messageID == nil }) ?? firstRetainedIndex
    guard
      let anchorIndex = entries[priorEntryCount...firstUnsavedIndex]
        .lastIndex(where: { $0.messageID != nil }), anchorIndex > priorEntryCount
    else { return nil }
    return priorEntryCount..<anchorIndex
  }
}

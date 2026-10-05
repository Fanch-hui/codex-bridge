import Foundation

/// Pure trimming policy for the active-task conversation window.
///
/// While a task streams, its entries grow without bound and hours-long
/// sessions exhaust renderer memory. `TaskConversationModel` applies this
/// policy after merging pushes and resync pages: entries older than the
/// retained window are dropped, and the user pages them back with the
/// existing `loadEarlier()` flow. That flow fetches by `beforeMessageID`, so
/// the retained window must still contain a message-ID anchor; when it does
/// not, nothing is trimmed because the dropped entries could never be
/// fetched back.
public enum TaskConversationWindowPolicy {
  public static let defaultMaximumCurrentTaskEntries = 400

  /// The index range of current-task entries to drop, or nil when the
  /// conversation must stay untouched (within the limit, or no paging anchor
  /// in the retained window).
  public static func currentTaskTrimRange(
    priorEntryCount: Int,
    entries: [TaskConversationModel.Entry],
    maximum: Int
  ) -> Range<Int>? {
    let currentEntryCount = entries.count - priorEntryCount
    guard maximum > 0, priorEntryCount >= 0, currentEntryCount > maximum else {
      return nil
    }
    let firstRetainedIndex = priorEntryCount + (currentEntryCount - maximum)
    guard
      let anchorIndex = entries[firstRetainedIndex...]
        .firstIndex(where: { $0.messageID != nil })
    else { return nil }
    return priorEntryCount..<anchorIndex
  }
}

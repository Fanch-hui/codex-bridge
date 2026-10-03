public struct TaskConversationPresentationUpdatePlan: Equatable {
  public let needsFullRebuild: Bool
  public let changedEntryIndices: [Int]
  public let appendedEntryRange: Range<Int>?

  public init(
    previous: [TaskConversationModel.Entry],
    next: [TaskConversationModel.Entry]
  ) {
    guard next.count >= previous.count, Self.hasSameKeys(previous, next) else {
      needsFullRebuild = true
      changedEntryIndices = []
      appendedEntryRange = nil
      return
    }

    needsFullRebuild = false
    changedEntryIndices = previous.indices.filter { previous[$0] != next[$0] }
    appendedEntryRange = next.count > previous.count ? previous.count..<next.count : nil
  }

  private static func hasSameKeys(
    _ previous: [TaskConversationModel.Entry],
    _ next: [TaskConversationModel.Entry]
  ) -> Bool {
    for index in previous.indices where previous[index].key != next[index].key {
      return false
    }
    return true
  }
}

public enum AgentTurnSummary {
  public static let separator = "\n\n---\n\n"

  /// Keeps every turn's final reply, so a later turn cannot erase an earlier
  /// turn's report. Overflow drops the tail, preserving chronological order.
  public static func combined(
    _ turns: [String],
    maximumUTF8Bytes: Int = 32 * 1_024
  ) -> String? {
    let kept = turns.filter {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard !kept.isEmpty else { return nil }
    let joined = kept.joined(separator: separator)
    guard joined.utf8.count > maximumUTF8Bytes else { return joined }
    return String(decoding: joined.utf8.prefix(maximumUTF8Bytes), as: UTF8.self)
  }
}

import Foundation

public enum AgentProgressText {
  public static let omissionMarker = "\n[…内容过长，后续已省略]"
  public static let maximumContentBytes = 256 * 1_024

  public static func bounded(_ value: String, maximumBytes: Int) -> String {
    guard value.utf8.count > maximumBytes else { return value }
    let marker =
      maximumBytes >= omissionMarker.utf8.count ? omissionMarker : (maximumBytes >= 3 ? "…" : "")
    let limit = max(0, maximumBytes - marker.utf8.count)
    let bytes = value.utf8
    var end = bytes.index(bytes.startIndex, offsetBy: min(limit, bytes.count))
    while end > bytes.startIndex, end < bytes.endIndex, bytes[end] & 0xC0 == 0x80 {
      end = bytes.index(before: end)
    }
    return String(decoding: bytes[..<end], as: UTF8.self) + marker
  }
}

public struct AgentProgressTextBuffer: Sendable {
  public private(set) var content = ""
  private var omitted = false

  public init() {}

  public mutating func append(
    _ text: String, key: String, role: AgentContentRole, kind: AgentContentKind
  ) throws -> AgentContentUpdate? {
    try AgentValidation.streamText(text, field: "content.content", maximumBytes: Int.max)
    guard !text.isEmpty, !omitted else { return nil }
    let baseLength = content.count
    let remaining = AgentProgressText.maximumContentBytes - content.utf8.count
    if text.utf8.count > remaining {
      content = AgentProgressText.bounded(
        content
          + AgentProgressText.bounded(
            text, maximumBytes: AgentProgressText.maximumContentBytes),
        maximumBytes: AgentProgressText.maximumContentBytes)
      omitted = true
      return try AgentContentUpdate(
        key: key, role: role, kind: kind, mode: .full, content: content,
        authoritative: true)
    }
    content.append(text)
    return try AgentContentUpdate(
      key: key, role: role, kind: kind, mode: .delta, content: text,
      baseContentLength: baseLength)
  }
}

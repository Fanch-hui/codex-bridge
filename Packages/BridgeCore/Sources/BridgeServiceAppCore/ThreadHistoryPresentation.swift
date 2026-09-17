import BridgeMCP

public enum ThreadHistoryPresentation {
  public struct Entry: Equatable, Sendable {
    public let id: String
    public let role: String
    public let text: String
  }

  public nonisolated static func title(_ thread: MCPThreadSummary) -> String {
    thread.title ?? thread.preview ?? thread.threadID
  }

  public nonisolated static func entries(_ page: MCPThreadReadPage?) -> [Entry] {
    guard let page else { return [] }
    return page.entries.enumerated().map { index, entry in
      Entry(
        id: "thread:\(page.thread.threadID):\(index)",
        role: entry.role == "user" ? "用户" : (entry.role == "assistant" ? "Codex" : entry.role),
        text: entry.text
      )
    }
  }
}

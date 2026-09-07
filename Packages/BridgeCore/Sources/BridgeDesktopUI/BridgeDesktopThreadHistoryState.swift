import Foundation

public struct BridgeDesktopThreadHistoryState: Codable, Equatable, Sendable {
  public let threads: [BridgeDesktopThreadRow]
  public let selectedThreadID: String?
  public let selectedThreadTitle: String?
  public let conversation: [BridgeDesktopConversationEntry]

  public init(
    threads: [BridgeDesktopThreadRow] = [],
    selectedThreadID: String? = nil,
    selectedThreadTitle: String? = nil,
    conversation: [BridgeDesktopConversationEntry] = []
  ) {
    self.threads = threads
    self.selectedThreadID = selectedThreadID
    self.selectedThreadTitle = selectedThreadTitle
    self.conversation = conversation
  }
}

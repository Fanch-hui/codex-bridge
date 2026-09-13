import BridgeServiceAppCore

public struct BridgeDesktopConversationState: Codable, Equatable, Sendable {
  public let errorMessage: String?
  public let isLoading: Bool
  public let isLoadingEarlier: Bool
  public let canLoadEarlier: Bool
  public let showsActivity: Bool
  public let statusText: String
  public let detailText: String?

  @MainActor
  public init(conversation: TaskConversationModel?, activity: CodexActivityPresentation) {
    errorMessage = conversation?.errorMessage
    isLoading = conversation?.isLoading ?? true
    isLoadingEarlier = conversation?.isLoadingEarlier ?? false
    canLoadEarlier = conversation?.canLoadEarlier ?? false
    showsActivity = activity.showsBubble
    statusText = activity.statusText
    detailText = activity.detailText
  }
}

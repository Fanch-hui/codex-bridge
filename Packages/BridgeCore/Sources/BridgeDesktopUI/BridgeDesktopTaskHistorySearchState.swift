import BridgeServiceAppCore
import Foundation

public struct BridgeDesktopTaskHistorySearchState: Codable, Equatable, Sendable {
  public struct Result: Codable, Equatable, Sendable {
    public let taskID: String
    public let title: String
    public let provider: String
    public let status: String
    public let updatedAt: String
  }

  public let search: String
  public let providerID: String?
  public let status: String?
  public let hasSearched: Bool
  public let isLoading: Bool
  public let canLoadMore: Bool
  public let errorMessage: String?
  public let nextOffset: Int
  public let results: [Result]
  public let providers: [BridgeDesktopChoice]

  public init(_ state: WorkbenchTaskHistorySearch, providers: [BridgeDesktopChoice]) {
    search = state.search
    providerID = state.providerID
    status = state.status
    hasSearched = state.hasSearched
    isLoading = state.isLoading
    canLoadMore = state.canLoadMore
    errorMessage = state.errorMessage
    nextOffset = state.nextOffset
    results = state.tasks.map {
      Result(
        taskID: $0.taskID,
        title: WorkbenchTaskTextPresentation.cleanTitle($0.prompt)
          ?? WorkbenchTaskTextPresentation.cleanTitle($0.workbenchTitle) ?? "未命名会话",
        provider: $0.providerDisplayName,
        status: WorkbenchTaskTextPresentation.statusLabel($0.status),
        updatedAt: $0.updatedAt)
    }
    self.providers = providers
  }
}

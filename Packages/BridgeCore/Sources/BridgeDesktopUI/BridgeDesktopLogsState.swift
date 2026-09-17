import Foundation

public struct BridgeDesktopLogRow: Codable, Equatable, Sendable {
  public let id: String
  public let sequence: Int64
  public let taskID: String
  public let projectID: String
  public let projectName: String
  public let kind: String
  public let kindLabel: String
  public let summary: String
  public let timestamp: String

  public init(
    id: String,
    sequence: Int64,
    taskID: String,
    projectID: String,
    projectName: String,
    kind: String,
    kindLabel: String,
    summary: String,
    timestamp: String
  ) {
    self.id = id
    self.sequence = sequence
    self.taskID = taskID
    self.projectID = projectID
    self.projectName = projectName
    self.kind = kind
    self.kindLabel = kindLabel
    self.summary = summary
    self.timestamp = timestamp
  }
}

public struct BridgeDesktopLogsState: Codable, Equatable, Sendable {
  public let header: BridgeDesktopPageHeader
  public let searchText: String
  public let projectOptions: [BridgeDesktopChoice]
  public let selectedProjectID: String?
  public let kindOptions: [BridgeDesktopChoice]
  public let selectedKind: String
  public let rows: [BridgeDesktopLogRow]
  public let selectedRowID: String?
  public let detailText: String?
  public let canCopy: Bool
  public let canRefresh: Bool

  public init(
    header: BridgeDesktopPageHeader,
    searchText: String = "",
    projectOptions: [BridgeDesktopChoice] = [],
    selectedProjectID: String? = nil,
    kindOptions: [BridgeDesktopChoice] = [],
    selectedKind: String = "all",
    rows: [BridgeDesktopLogRow] = [],
    selectedRowID: String? = nil,
    detailText: String? = nil,
    canCopy: Bool = false,
    canRefresh: Bool = true
  ) {
    self.header = header
    self.searchText = searchText
    self.projectOptions = projectOptions
    self.selectedProjectID = selectedProjectID
    self.kindOptions = kindOptions
    self.selectedKind = selectedKind
    self.rows = rows
    self.selectedRowID = selectedRowID
    self.detailText = detailText
    self.canCopy = canCopy
    self.canRefresh = canRefresh
  }
}

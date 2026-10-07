import BridgeMCP
import Foundation

public struct WorkbenchTaskHistorySearch: Equatable, Sendable {
  public var search = ""
  public var providerID: String?
  public var status: String?
  public var hasSearched = false
  public var isLoading = false
  public var canLoadMore = false
  public var errorMessage: String?
  public var tasks: [MCPServiceTaskSnapshot] = []
  public var nextOffset = 0

  public init() {}

  public mutating func begin(search: String?, providerID: String?, status: String?) {
    self = Self()
    self.search = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.providerID = providerID?.isEmpty == false ? providerID : nil
    self.status = status?.isEmpty == false ? status : nil
    hasSearched = true
    isLoading = true
  }

  public mutating func append(_ page: [MCPServiceTaskSnapshot], limit: Int) {
    canLoadMore = page.count > limit
    let accepted = Array(page.prefix(limit))
    let knownIDs = Set(tasks.map(\.taskID))
    tasks.append(contentsOf: accepted.filter { !knownIDs.contains($0.taskID) })
    nextOffset += accepted.count
    isLoading = false
    errorMessage = nil
  }

  public static func retainingSelection(
    in recent: [MCPServiceTaskSnapshot], prior: [MCPServiceTaskSnapshot],
    selectedTaskID: String?, historyTaskID: String?
  ) -> [MCPServiceTaskSnapshot] {
    guard let selectedTaskID, selectedTaskID == historyTaskID,
      !recent.contains(where: { $0.taskID == selectedTaskID }),
      let selected = prior.first(where: { $0.taskID == selectedTaskID })
    else { return recent }
    return recent + [selected]
  }
}

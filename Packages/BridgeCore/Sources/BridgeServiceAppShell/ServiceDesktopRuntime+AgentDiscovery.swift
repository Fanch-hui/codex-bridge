import Foundation

extension BridgeServiceAppModel {
  public func scanAgents() {
    guard !isManagingAgents else { return }
    isManagingAgents = true
    errorMessage = nil
    Task { [weak self] in
      guard let self else { return }
      defer { self.isManagingAgents = false }
      do {
        let client = try self.currentClient()
        let catalog = try await client.agentCatalog(forceRefresh: true)
        self.applyAgentCatalogSnapshot(catalog)
        self.postToast("Agent 扫描完成", symbol: "checkmark.circle.fill")
      } catch {
        self.errorMessage = Self.message(error)
      }
    }
  }
}

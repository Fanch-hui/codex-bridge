import BridgeServiceAppCore

extension BridgeServiceAppModel {
  /// Shows the given sessions (by their latest task) in the web workbench split view.
  func setWorkbenchPanes(_ taskIDs: [String]) {
    let changed = paneConversations.setPanes(taskIDs, tasks: tasks, client: client)
    let active = Set(paneConversations.paneTaskIDs)
    panePresentationCaches = panePresentationCaches.filter { active.contains($0.key) }
    if changed { objectWillChange.send() }
  }

  func closeWorkbenchPanes() {
    paneConversations.removeAll()
    panePresentationCaches = [:]
  }
}

import BridgeDesktopUI
import BridgeServiceAppCore

extension BridgeDesktopUIStateBuilder {
  static func threadHistory(from model: BridgeServiceAppModel) -> BridgeDesktopThreadHistoryState {
    let projectTasks = model.tasks.filter {
      model.selectedProjectID == nil || $0.projectID == model.selectedProjectID
    }
    let threads = WorkbenchSessionCatalog.orphanThreads(tasks: projectTasks, threads: model.threads)
    let selectedID = model.selectedTaskID == nil ? model.selectedThreadID : nil
    let page = model.selectedThread.flatMap { $0.thread.threadID == selectedID ? $0 : nil }
    return BridgeDesktopThreadHistoryState(
      threads: threads.map {
        BridgeDesktopThreadRow(
          threadID: $0.threadID,
          title: ThreadHistoryPresentation.title($0),
          status: $0.status,
          updatedAt: $0.updatedAt,
          preview: $0.preview
        )
      },
      selectedThreadID: selectedID,
      selectedThreadTitle: page.map { ThreadHistoryPresentation.title($0.thread) }
        ?? threads.first(where: { $0.threadID == selectedID }).map(ThreadHistoryPresentation.title),
      conversation: ThreadHistoryPresentation.entries(page).map {
        BridgeDesktopConversationEntry(id: $0.id, role: $0.role, text: $0.text)
      }
    )
  }
}

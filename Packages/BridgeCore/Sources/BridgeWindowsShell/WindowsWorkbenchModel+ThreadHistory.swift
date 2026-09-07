#if os(Windows)
  import BridgeDesktopUI
  import BridgeServiceAppCore

  extension WindowsWorkbenchModel {
    func threadHistory() -> BridgeDesktopThreadHistoryState {
      let selectedID = selectedTaskID == nil ? selectedThreadID : nil
      let page = selectedThreadPage.flatMap { $0.thread.threadID == selectedID ? $0 : nil }
      return BridgeDesktopThreadHistoryState(
        threads: orphanThreads.map {
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
          ?? threads.first(where: { $0.threadID == selectedID }).map(
            ThreadHistoryPresentation.title),
        conversation: ThreadHistoryPresentation.entries(page).map {
          BridgeDesktopConversationEntry(id: $0.id, role: $0.role, text: $0.text)
        }
      )
    }
  }
#endif

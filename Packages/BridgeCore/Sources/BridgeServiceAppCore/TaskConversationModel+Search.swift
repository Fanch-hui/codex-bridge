import BridgeIPC

extension TaskConversationModel {
  public func requestSearchReveal(_ messageID: Int64) {
    guard messageID > 0, messageID < Int64.max else { return }
    searchRevealGeneration &+= 1
    if isLoading {
      pendingSearchReveal = messageID
      return
    }
    isLoadingEarlier = false
    let reveal = searchRevealGeneration
    Task { [weak self] in
      await self?.loadSearchMessage(messageID, reveal: reveal)
    }
  }

  private func loadSearchMessage(_ messageID: Int64, reveal: UInt64) async {
    let lifecycle = lifecycleGeneration
    let load = loadGeneration
    if entries.contains(where: { $0.messageID == messageID }) {
      requestAutoScroll()
      return
    }
    isLoadingEarlier = true
    requestAutoScroll()
    defer {
      if reveal == searchRevealGeneration {
        isLoadingEarlier = false
        requestAutoScroll()
      }
    }
    do {
      let page = try await client.taskConversation(
        IPCTaskConversationRequest(
          taskID: taskID, beforeMessageID: messageID + 1, limit: Self.earlierPageSize))
      guard isRequestValid(lifecycle: lifecycle, load: load), reveal == searchRevealGeneration,
        page.taskID == taskID, page.messages.contains(where: { $0.messageID == messageID })
      else { return }
      isBrowsingHistory = true
      autoScroll = false
      entries = priorEntries + page.messages.map { Entry($0, isFinal: $0.final) }
      canLoadEarlierCurrentTask = page.messages.count >= Self.earlierPageSize
      updateEarlierAvailability()
      rebuildIndex()
    } catch {
      guard isRequestValid(lifecycle: lifecycle, load: load), reveal == searchRevealGeneration
      else {
        return
      }
      errorMessage = BridgeServiceErrorMessage.message(error)
    }
  }
}

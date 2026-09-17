import BridgeIPC

extension TaskConversationModel {
  struct PriorTaskHistory {
    var entries: [Entry]
    var beforeMessageID: Int64?
    var canLoadEarlier: Bool
  }

  public func loadEarlier() async {
    flushPendingPushes()
    guard canLoadEarlier, !isLoadingEarlier else { return }
    let lifecycle = lifecycleGeneration
    let load = loadGeneration
    isLoadingEarlier = true
    defer { isLoadingEarlier = false }

    if canLoadEarlierCurrentTask {
      await loadEarlierCurrentTask(lifecycle: lifecycle, load: load)
      updateEarlierAvailability()
      return
    }

    guard
      let priorID = priorTaskIDs.reversed().first(where: {
        priorTaskHistories[$0]?.canLoadEarlier == true
      })
    else {
      canLoadEarlier = false
      return
    }
    await loadEarlierPriorTask(priorID, lifecycle: lifecycle, load: load)
    updateEarlierAvailability()
  }

  private func loadEarlierCurrentTask(lifecycle: UInt64, load: UInt64) async {
    let currentEntries = entries.dropFirst(priorEntries.count)
    guard let anchor = currentEntries.first(where: { $0.messageID != nil })?.messageID else {
      canLoadEarlierCurrentTask = false
      return
    }
    do {
      let page = try await client.taskConversation(
        IPCTaskConversationRequest(
          taskID: taskID,
          beforeMessageID: anchor,
          limit: Self.earlierPageSize
        )
      )
      guard isRequestValid(lifecycle: lifecycle, load: load) else { return }
      guard page.taskID == taskID else {
        canLoadEarlierCurrentTask = false
        return
      }
      canLoadEarlierCurrentTask = page.messages.count >= Self.earlierPageSize
      guard !page.messages.isEmpty else {
        canLoadEarlierCurrentTask = false
        return
      }
      let older = page.messages
        .filter { index[$0.key] == nil }
        .map { Entry($0, isFinal: true) }
      guard !older.isEmpty else {
        canLoadEarlierCurrentTask = false
        return
      }
      let latestCurrentEntries = entries.dropFirst(priorEntries.count)
      entries = priorEntries + older + Array(latestCurrentEntries)
      rebuildIndex()
      scrollAnchor = entries.last?.key
    } catch {
      guard isRequestValid(lifecycle: lifecycle, load: load) else { return }
      errorMessage = BridgeServiceErrorMessage.message(error)
    }
  }

  private func loadEarlierPriorTask(
    _ priorID: String,
    lifecycle: UInt64,
    load: UInt64
  ) async {
    guard var history = priorTaskHistories[priorID], history.canLoadEarlier,
      let anchor = history.beforeMessageID
    else { return }
    do {
      let page = try await client.taskConversation(
        IPCTaskConversationRequest(
          taskID: priorID,
          beforeMessageID: anchor,
          limit: Self.earlierPageSize
        )
      )
      guard isRequestValid(lifecycle: lifecycle, load: load) else { return }
      guard page.taskID == priorID else {
        history.canLoadEarlier = false
        priorTaskHistories[priorID] = history
        return
      }
      let older = page.messages.filter { message in
        !history.entries.contains {
          $0.key == priorID + ":" + message.key
        }
      }
      .map { Entry($0, isFinal: true, keyPrefix: priorID) }
      let nextBeforeMessageID = page.messages.first?.messageID
      history.canLoadEarlier =
        page.messages.count >= Self.earlierPageSize
        && nextBeforeMessageID != nil
        && nextBeforeMessageID != anchor
      history.beforeMessageID = nextBeforeMessageID
      guard !page.messages.isEmpty, !older.isEmpty else {
        history.canLoadEarlier = false
        priorTaskHistories[priorID] = history
        return
      }
      history.entries = older + history.entries
      priorTaskHistories[priorID] = history
      replacePriorEntriesPreservingCurrent()
    } catch {
      guard isRequestValid(lifecycle: lifecycle, load: load) else { return }
      errorMessage = BridgeServiceErrorMessage.message(error)
    }
  }

  func updateEarlierAvailability() {
    canLoadEarlier =
      canLoadEarlierCurrentTask
      || priorTaskIDs.contains { priorTaskHistories[$0]?.canLoadEarlier == true }
  }

  func loadPriorTasks() async {
    guard !priorTaskIDs.isEmpty else { return }
    let restoredEntries = entries
    priorTaskHistories.removeAll(keepingCapacity: true)
    for (index, priorID) in priorTaskIDs.enumerated() {
      let cached = restoredEntries.filter { $0.key.hasPrefix(priorID + ":") }
      priorTaskHistories[priorID] = await loadInitialPriorTaskHistory(
        taskID: priorID,
        pageCount: index == priorTaskIDs.index(before: priorTaskIDs.endIndex)
          ? Self.initialPriorPageCount : 1,
        cached: cached
      )
    }
    replacePriorEntriesPreservingCurrent()
    updateEarlierAvailability()
    requestAutoScroll()
  }

  private func loadInitialPriorTaskHistory(
    taskID: String,
    pageCount: Int,
    cached: [Entry]
  ) async -> PriorTaskHistory {
    var pages: [[Entry]] = []
    var beforeMessageID: Int64?

    for _ in 0..<max(1, pageCount) {
      do {
        let page = try await client.taskConversation(
          IPCTaskConversationRequest(
            taskID: taskID,
            beforeMessageID: beforeMessageID,
            limit: Self.conversationPageSize
          )
        )
        guard page.taskID == taskID, !page.messages.isEmpty else {
          break
        }
        let entries = page.messages.map {
          Entry($0, isFinal: true, keyPrefix: taskID)
        }
        pages.insert(entries, at: 0)
        guard entries.count >= Self.conversationPageSize,
          let firstMessageID = page.messages.first?.messageID,
          firstMessageID != beforeMessageID
        else {
          beforeMessageID = nil
          break
        }
        beforeMessageID = firstMessageID
      } catch {
        break
      }
    }

    let loaded = pages.flatMap { $0 }
    guard !loaded.isEmpty else {
      let cachedBefore = cached.first?.messageID
      return PriorTaskHistory(
        entries: cached,
        beforeMessageID: cachedBefore,
        canLoadEarlier: cachedBefore != nil && cached.first?.role != "user"
      )
    }
    return PriorTaskHistory(
      entries: loaded,
      beforeMessageID: beforeMessageID,
      canLoadEarlier: beforeMessageID != nil
    )
  }

  private func replacePriorEntriesPreservingCurrent() {
    let currentEntries = entries.filter { entry in
      !priorTaskIDs.contains(where: { entry.key.hasPrefix($0 + ":") })
    }
    priorEntries = priorTaskIDs.flatMap { priorTaskHistories[$0]?.entries ?? [] }
    entries = priorEntries + currentEntries
    rebuildIndex()
  }
}

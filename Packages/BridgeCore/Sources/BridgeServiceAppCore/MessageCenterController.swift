import BridgeSecurity
import Foundation

@MainActor
public final class MessageCenterController {
  public private(set) var state = MessageCenterState() {
    didSet { if oldValue != state { onChange(state) } }
  }

  private let version: String
  private let platform: String
  private let client: MessageCenterClient
  private let secrets: any SecretStore
  private let onChange: @MainActor @Sendable (MessageCenterState) -> Void
  private var storage: MessageCenterStorage?
  private var saved = MessageCenterSavedState()
  private var refreshTask: Task<Void, Never>?
  private var submissionTask: Task<Void, Never>?
  private var attachmentTasks: [UUID: Task<URL, any Error>] = [:]
  private var activeAttachmentIDs: Set<String> = []
  private var timerTask: Task<Void, Never>?
  private var started = false
  private var foregroundVisible = true
  private var lastRefresh: Date?
  private var nextNoticeCursor: String?

  public convenience init(
    currentVersion: String, platform: String,
    onChange: @escaping @MainActor @Sendable (MessageCenterState) -> Void
  ) {
    self.init(
      currentVersion: currentVersion, platform: platform, client: MessageCenterClient(),
      secrets: SecretStoreFactory.defaultStore(), root: nil, onChange: onChange)
  }

  init(
    currentVersion: String, platform: String, client: MessageCenterClient,
    secrets: any SecretStore, root: URL?,
    onChange: @escaping @MainActor @Sendable (MessageCenterState) -> Void
  ) {
    version = currentVersion
    self.platform = platform
    self.client = client
    self.secrets = secrets
    self.onChange = onChange
    state.appVersion = currentVersion
    state.platform = platform
    do {
      let storage = try MessageCenterStorage(root: root)
      saved = try storage.load()
      self.storage = storage
      rebuildPresentation()
    } catch {
      state.error = "无法读取消息中心的本机数据，请检查本机存储。"
    }
  }

  public func start() {
    guard !started else { return }
    started = true
    refresh()
    timerTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1_800))
        guard !Task.isCancelled, let self else { return }
        if foregroundVisible { refresh() }
      }
    }
  }

  public func stop() {
    started = false
    timerTask?.cancel()
    refreshTask?.cancel()
    submissionTask?.cancel()
    for task in attachmentTasks.values { task.cancel() }
    attachmentTasks.removeAll()
    timerTask = nil
    refreshTask = nil
    submissionTask = nil
    state.isRefreshing = false
    state.isSubmitting = false
    do { try storage?.cleanDownloads() } catch { state.error = "无法清理临时图片。" }
  }

  public func setForegroundVisible(_ visible: Bool) {
    let becameVisible = !foregroundVisible && visible
    foregroundVisible = visible
    if started && becameVisible
      && (lastRefresh.map { Date().timeIntervalSince($0) >= 1_800 } ?? true)
    {
      refresh()
    }
  }

  public func refresh() {
    guard refreshTask == nil, storage != nil else { return }
    state.isRefreshing = true
    state.error = nil
    let entries = saved.feedbacks
    refreshTask = Task { [weak self] in
      guard let self else { return }
      var encounteredError = false
      var networkUnavailable = false
      do {
        var notices: [MessageCenterNoticeRecord] = []
        var ids: Set<String> = []
        var cursors: Set<String> = []
        var cursor: String?
        for _ in 0..<10 {
          let page = try await client.notices(platform: platform, version: version, cursor: cursor)
          try Task.checkCancellation()
          for notice in page.notices where ids.insert(notice.id).inserted { notices.append(notice) }
          cursor = page.nextCursor
          guard let next = cursor else { break }
          guard cursors.insert(next).inserted else {
            throw MessageCenterClientError.invalidResponse
          }
        }
        saved.notices = notices
        nextNoticeCursor = cursor
        state.hasMoreNotices = cursor != nil
      } catch {
        if Task.isCancelled { return }
        encounteredError = true
        if let networkError = error as? URLError {
          networkUnavailable = [
            .notConnectedToInternet, .timedOut, .cannotConnectToHost, .cannotFindHost,
            .networkConnectionLost, .dnsLookupFailed, .secureConnectionFailed,
          ].contains(networkError.code)
        }
      }
      if !networkUnavailable {
        let client = self.client
        let secrets = self.secrets
        for start in stride(from: 0, to: entries.count, by: 3) {
          if Task.isCancelled { return }
          let batch = entries[start..<min(start + 3, entries.count)]
          let results = await withTaskGroup(of: (String, MessageCenterFeedbackRecord?).self) {
            group in
            for entry in batch {
              group.addTask {
                do {
                  let token = try Self.loadToken(entry.secretReference, secrets: secrets)
                  let feedback = try await client.feedback(id: entry.feedback.id, token: token)
                  guard feedback.id == entry.feedback.id else { return (entry.feedback.id, nil) }
                  return (entry.feedback.id, feedback)
                } catch {
                  return (entry.feedback.id, nil)
                }
              }
            }
            var values: [(String, MessageCenterFeedbackRecord?)] = []
            for await value in group { values.append(value) }
            return values
          }
          for (id, feedback) in results {
            guard let feedback else {
              encounteredError = true
              continue
            }
            if let index = saved.feedbacks.firstIndex(where: { $0.feedback.id == id }),
              saved.feedbacks[index].feedback.updatedAt <= feedback.updatedAt
            {
              saved.feedbacks[index].feedback = feedback
            }
          }
        }
      }
      if Task.isCancelled { return }
      lastRefresh = Date()
      let persisted = persist()
      rebuildPresentation()
      if persisted { state.error = encounteredError ? "部分消息暂时无法刷新，请稍后重试。" : nil }
      state.isRefreshing = false
      refreshTask = nil
    }
  }

  public func loadMoreNotices() {
    guard refreshTask == nil, let cursor = nextNoticeCursor, storage != nil else { return }
    state.isRefreshing = true
    state.error = nil
    refreshTask = Task { [weak self] in
      guard let self else { return }
      do {
        let page = try await client.notices(platform: platform, version: version, cursor: cursor)
        try Task.checkCancellation()
        guard page.nextCursor != cursor else { throw MessageCenterClientError.invalidResponse }
        let previous = saved
        var ids = Set(saved.notices.map(\.id))
        for notice in page.notices where ids.insert(notice.id).inserted {
          saved.notices.append(notice)
        }
        if saved.notices.count > 500 { saved.notices.removeFirst(saved.notices.count - 500) }
        guard persist() else {
          saved = previous
          throw MessageCenterStorageError.storageUnavailable
        }
        nextNoticeCursor = page.nextCursor
        state.hasMoreNotices = page.nextCursor != nil
        rebuildPresentation()
      } catch {
        if Task.isCancelled { return }
        state.error = error.localizedDescription
      }
      state.isRefreshing = false
      refreshTask = nil
    }
  }

  public func markRead(kind: String, id: String) {
    if kind == "notice", let notice = saved.notices.first(where: { $0.id == id }) {
      saved.readNotices[id] = notice.revision
    } else if kind == "feedback",
      let feedback = saved.feedbacks.first(where: { $0.feedback.id == id })
    {
      saved.readMessages.formUnion(
        feedback.feedback.messages.filter { $0.author == "admin" }.map(\.id))
    } else {
      return
    }
    if persist() { rebuildPresentation() }
  }

  public func markAllRead() {
    for notice in saved.notices { saved.readNotices[notice.id] = notice.revision }
    for feedback in saved.feedbacks {
      saved.readMessages.formUnion(
        feedback.feedback.messages.filter { $0.author == "admin" }.map(\.id))
    }
    if persist() { rebuildPresentation() }
  }

  public func submitFeedback(category: String, body: String) {
    guard ["bug", "suggestion", "other"].contains(category) else { return }
    submit(feedbackID: nil, category: category, body: body)
  }

  public func reply(feedbackID: String, body: String) {
    guard UUID(uuidString: feedbackID) != nil,
      let entry = saved.feedbacks.first(where: { $0.feedback.id == feedbackID })
    else { return }
    submit(feedbackID: feedbackID, category: entry.feedback.category, body: body)
  }

  public func addAttachments(paths: [String], feedbackID: String?) {
    guard let storage else {
      state.submissionError = MessageCenterStorageError.storageUnavailable.localizedDescription
      return
    }
    if let feedbackID, !saved.feedbacks.contains(where: { $0.feedback.id == feedbackID }) { return }
    let existing = saved.draftAttachments.filter { $0.feedbackID == feedbackID }
    guard !paths.isEmpty else { return }
    guard existing.count + paths.count <= 3 else {
      state.submissionError = MessageCenterStorageError.attachmentLimit.localizedDescription
      return
    }
    var added: [MessageCenterDraftAttachment] = []
    do {
      for path in paths { added.append(try storage.addDraft(path: path, feedbackID: feedbackID)) }
      guard (existing + added).reduce(0, { $0 + $1.size }) <= 10 * 1_024 * 1_024 else {
        throw MessageCenterStorageError.attachmentLimit
      }
      saved.draftAttachments.append(contentsOf: added)
      guard persist() else { throw MessageCenterStorageError.storageUnavailable }
      state.submissionError = nil
      rebuildPresentation()
    } catch {
      saved.draftAttachments.removeAll { item in added.contains(where: { $0.id == item.id }) }
      for item in added { try? storage.removeDraft(id: item.id) }
      state.submissionError = error.localizedDescription
    }
  }

  public func removeAttachment(id: String, feedbackID: String?) {
    guard
      let index = saved.draftAttachments.firstIndex(where: {
        $0.id == id && $0.feedbackID == feedbackID
      })
    else { return }
    let item = saved.draftAttachments.remove(at: index)
    guard persist() else {
      saved.draftAttachments.insert(item, at: index)
      return
    }
    if !activeAttachmentIDs.contains(id),
      !saved.pending.values.contains(where: { $0.attachments.contains(where: { $0.id == id }) })
    {
      do { try storage?.removeDraft(id: id) } catch { state.submissionError = "无法删除本机截图。" }
    }
    rebuildPresentation()
  }

  public func attachmentURL(id: String, feedbackID: String?) -> URL? {
    guard
      let item = saved.draftAttachments.first(where: { $0.id == id && $0.feedbackID == feedbackID }
      ),
      let storage
    else { return nil }
    do {
      let bytes = try Data(contentsOf: storage.draftURL(id: id), options: .mappedIfSafe)
      guard bytes.count == item.size, storage.imageContentType(bytes) == item.contentType else {
        throw MessageCenterStorageError.invalidImage
      }
      return try storage.saveDownload(id: id, bytes: bytes, contentType: item.contentType)
    } catch {
      state.submissionError = error.localizedDescription
      return nil
    }
  }

  public func downloadAttachment(id: String, feedbackID: String) async throws -> URL {
    let operationID = UUID()
    let task = Task { [weak self] () throws -> URL in
      guard let self else { throw CancellationError() }
      do {
        guard UUID(uuidString: id) != nil,
          let entry = saved.feedbacks.first(where: { $0.feedback.id == feedbackID }),
          let attachment = entry.feedback.messages.lazy.compactMap({ $0.attachments }).joined()
            .first(where: { $0.id == id }),
          let storage
        else { throw MessageCenterStorageError.missingFeedback }
        let token = try loadToken(entry.secretReference)
        let (bytes, contentType) = try await client.download(id: id, token: token)
        try Task.checkCancellation()
        guard bytes.count == attachment.size,
          storage.imageContentType(bytes) == attachment.contentType,
          contentType?.split(separator: ";").first == Substring(attachment.contentType)
        else { throw MessageCenterClientError.invalidResponse }
        return try storage.saveDownload(id: id, bytes: bytes, contentType: attachment.contentType)
      } catch {
        if !Task.isCancelled { state.error = error.localizedDescription }
        throw error
      }
    }
    attachmentTasks[operationID] = task
    defer { attachmentTasks.removeValue(forKey: operationID) }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func rebuildPresentation() {
    state.notices = saved.notices.map {
      $0.presentation(isRead: (saved.readNotices[$0.id] ?? 0) >= $0.revision)
    }
    state.feedbacks = saved.feedbacks.map {
      $0.feedback.presentation(seenMessages: saved.readMessages)
    }
    .sorted { $0.updatedAt > $1.updatedAt }
    state.unreadCount =
      state.notices.filter { !$0.isRead }.count + state.feedbacks.reduce(0) { $0 + $1.unreadCount }
    state.draftAttachments = saved.draftAttachments
  }

  @discardableResult
  private func persist() -> Bool {
    do {
      guard let storage else { throw MessageCenterStorageError.storageUnavailable }
      try storage.save(saved)
      return true
    } catch {
      state.error = "无法保存消息中心的本机数据，请检查本机存储。"
      return false
    }
  }

  private func loadToken(_ value: String) throws -> String {
    try Self.loadToken(value, secrets: secrets)
  }

  private nonisolated static func loadToken(_ value: String, secrets: any SecretStore) throws
    -> String
  {
    let bytes = try secrets.load(SecretReference(validating: value))
    guard let token = String(data: bytes, encoding: .utf8), token.count == 64,
      token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw MessageCenterStorageError.missingFeedback }
    return token
  }
}

extension MessageCenterController {
  private func submit(feedbackID: String?, category: String, body: String) {
    guard submissionTask == nil else { return }
    var nextState = state
    nextState.submissionAttemptID = UUID().uuidString.lowercased()
    guard storage != nil else {
      nextState.submissionError = MessageCenterStorageError.storageUnavailable.localizedDescription
      state = nextState
      return
    }
    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      body.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count <= 16_000
    else {
      nextState.submissionError = "请填写不超过 16000 字节的反馈内容。"
      state = nextState
      return
    }
    let scope = feedbackID ?? "new"
    var attachments = saved.draftAttachments.filter { $0.feedbackID == feedbackID }
    activeAttachmentIDs = Set(attachments.map(\.id))
    nextState.isSubmitting = true
    nextState.submissionError = nil
    state = nextState
    submissionTask = Task { [weak self] in
      guard let self else { return }
      defer {
        let finishedIDs = activeAttachmentIDs
        activeAttachmentIDs = []
        for id in finishedIDs
        where !saved.draftAttachments.contains(where: { $0.id == id })
          && !saved.pending.values.contains(where: {
            $0.attachments.contains(where: { $0.id == id })
          })
        {
          do { try storage?.removeDraft(id: id) } catch { state.error = "无法删除本机截图副本。" }
        }
        submissionTask = nil
        state.isSubmitting = false
      }
      do {
        if let pending = saved.pending[scope] {
          let same =
            pending.feedbackID == feedbackID && pending.category == category
            && pending.body == body && pending.attachments.map(\.id) == attachments.map(\.id)
          if !same && pending.definitivelyRejected == true {
            let replacement = try replaceRejected(
              pending, feedbackID: feedbackID, category: category, body: body,
              attachments: attachments)
            let result = try await execute(replacement)
            try Task.checkCancellation()
            try finalize(replacement, result: result, keeping: [])
            state.submissionReceipt = receipt(replacement, feedback: result)
            return
          }
          let result = try await execute(pending)
          try Task.checkCancellation()
          if same {
            try finalize(pending, result: result, keeping: [])
            state.submissionReceipt = receipt(pending, feedback: result)
            return
          }
          let keep = Set(attachments.map(\.id))
          try finalize(pending, result: result, keeping: keep)
          attachments = try copyReusedAttachments(attachments, previous: pending)
        }
        let pending = try begin(
          feedbackID: feedbackID, category: category, body: body, attachments: attachments)
        let result = try await execute(pending)
        try Task.checkCancellation()
        try finalize(pending, result: result, keeping: [])
        state.submissionReceipt = receipt(pending, feedback: result)
      } catch {
        if !Task.isCancelled {
          recordDefinitiveFailure(error, scope: scope)
          state.submissionError = error.localizedDescription
        }
      }
    }
  }

  private func recordDefinitiveFailure(_ error: Error, scope: String) {
    guard var pending = saved.pending[scope] else { return }
    let rejected: Bool
    switch error {
    case MessageCenterClientError.service(let code, _):
      rejected = [
        "invalid_request", "unauthorized", "forbidden", "not_found", "too_large", "rate_limited",
      ].contains(code)
    case MessageCenterClientError.httpStatus(let status):
      rejected = [400, 401, 403, 404, 413, 422, 429].contains(status)
    default: rejected = false
    }
    guard rejected else { return }
    pending.definitivelyRejected = true
    saved.pending[scope] = pending
    _ = persist()
  }

  private func replaceRejected(
    _ previous: MessageCenterPendingSubmission, feedbackID: String?, category: String,
    body: String, attachments: [MessageCenterDraftAttachment]
  ) throws -> MessageCenterPendingSubmission {
    let replacement = MessageCenterPendingSubmission(
      requestID: UUID().uuidString.lowercased(), feedbackID: feedbackID, category: category,
      body: body, secretReference: previous.secretReference, attachments: attachments)
    let scope = feedbackID ?? "new"
    saved.pending[scope] = replacement
    guard persist() else {
      saved.pending[scope] = previous
      throw MessageCenterStorageError.storageUnavailable
    }
    let keptIDs = Set(attachments.map(\.id))
    for old in previous.attachments
    where !keptIDs.contains(old.id)
      && !saved.draftAttachments.contains(where: { $0.id == old.id })
    {
      do { try storage?.removeDraft(id: old.id) } catch { state.error = "无法删除本机截图副本。" }
    }
    return replacement
  }

  private func begin(
    feedbackID: String?, category: String, body: String, attachments: [MessageCenterDraftAttachment]
  ) throws -> MessageCenterPendingSubmission {
    let reference: String
    if let feedbackID {
      guard let entry = saved.feedbacks.first(where: { $0.feedback.id == feedbackID }) else {
        throw MessageCenterStorageError.missingFeedback
      }
      reference = entry.secretReference
    } else {
      let secretReference = SecretReference.random(prefix: "message-center-feedback")
      var generator = SystemRandomNumberGenerator()
      let token = (0..<32).map { _ in
        String(format: "%02x", UInt8.random(in: 0...255, using: &generator))
      }.joined()
      try secrets.store(Data(token.utf8), for: secretReference)
      reference = secretReference.rawValue
    }
    let pending = MessageCenterPendingSubmission(
      requestID: UUID().uuidString.lowercased(), feedbackID: feedbackID, category: category,
      body: body, secretReference: reference, attachments: attachments)
    let scope = feedbackID ?? "new"
    saved.pending[scope] = pending
    guard persist() else {
      saved.pending.removeValue(forKey: scope)
      if feedbackID == nil { try? secrets.remove(SecretReference(validating: reference)) }
      throw MessageCenterStorageError.storageUnavailable
    }
    return pending
  }

  private func execute(_ pending: MessageCenterPendingSubmission) async throws
    -> MessageCenterFeedbackRecord
  {
    guard let storage else { throw MessageCenterStorageError.storageUnavailable }
    let token = try loadToken(pending.secretReference)
    for attachment in pending.attachments {
      let bytes = try Data(contentsOf: storage.draftURL(id: attachment.id), options: .mappedIfSafe)
      guard bytes.count == attachment.size,
        storage.imageContentType(bytes) == attachment.contentType
      else {
        throw MessageCenterStorageError.invalidImage
      }
      try await client.upload(attachment, bytes: bytes, token: token)
    }
    let references = pending.attachments.map { MessageCenterAttachmentReference(id: $0.id) }
    let result: MessageCenterFeedbackRecord
    if let feedbackID = pending.feedbackID {
      result = try await client.reply(
        id: feedbackID,
        MessageCenterReplyRequest(
          requestId: pending.requestID, body: pending.body, attachments: references), token: token)
      guard result.id == feedbackID else { throw MessageCenterClientError.invalidResponse }
    } else {
      result = try await client.create(
        MessageCenterCreateRequest(
          requestId: pending.requestID, category: pending.category, body: pending.body,
          appVersion: version, platform: platform, attachments: references), token: token)
    }
    guard UUID(uuidString: result.id) != nil else { throw MessageCenterClientError.invalidResponse }
    return result
  }

  private func finalize(
    _ pending: MessageCenterPendingSubmission, result: MessageCenterFeedbackRecord,
    keeping: Set<String>
  ) throws {
    let previous = saved
    if let index = saved.feedbacks.firstIndex(where: { $0.feedback.id == result.id }) {
      if saved.feedbacks[index].feedback.updatedAt <= result.updatedAt {
        saved.feedbacks[index].feedback = result
      }
    } else {
      saved.feedbacks.append(
        MessageCenterSavedFeedback(feedback: result, secretReference: pending.secretReference))
    }
    saved.pending.removeValue(forKey: pending.feedbackID ?? "new")
    let ids = Set(pending.attachments.map(\.id)).subtracting(keeping)
    saved.draftAttachments.removeAll { ids.contains($0.id) }
    guard persist() else {
      saved = previous
      throw MessageCenterStorageError.storageUnavailable
    }
    for id in ids where !saved.draftAttachments.contains(where: { $0.id == id }) {
      do { try storage?.removeDraft(id: id) } catch { state.error = "无法删除已发送的本机截图。" }
    }
    rebuildPresentation()
  }

  private func copyReusedAttachments(
    _ attachments: [MessageCenterDraftAttachment], previous: MessageCenterPendingSubmission
  ) throws -> [MessageCenterDraftAttachment] {
    guard let storage else { throw MessageCenterStorageError.storageUnavailable }
    let oldIDs = Set(previous.attachments.map(\.id))
    var replacements: [(MessageCenterDraftAttachment, MessageCenterDraftAttachment)] = []
    do {
      for item in attachments where oldIDs.contains(item.id) {
        let copy = try storage.addDraft(
          path: storage.draftURL(id: item.id).path, feedbackID: item.feedbackID)
        let renamed = MessageCenterDraftAttachment(
          id: copy.id, name: item.name, contentType: copy.contentType,
          size: copy.size, feedbackID: copy.feedbackID)
        replacements.append((item, renamed))
      }
      let previousState = saved
      for (old, new) in replacements {
        if let index = saved.draftAttachments.firstIndex(where: { $0.id == old.id }) {
          saved.draftAttachments[index] = new
        }
      }
      guard persist() else {
        saved = previousState
        throw MessageCenterStorageError.storageUnavailable
      }
      for (old, _) in replacements {
        do { try storage.removeDraft(id: old.id) } catch { state.error = "无法删除本机截图副本。" }
      }
      rebuildPresentation()
      return attachments.map { item in replacements.first(where: { $0.0.id == item.id })?.1 ?? item
      }
    } catch {
      for (_, item) in replacements { try? storage.removeDraft(id: item.id) }
      throw error
    }
  }

  private func receipt(
    _ pending: MessageCenterPendingSubmission, feedback: MessageCenterFeedbackRecord
  ) -> MessageCenterSubmissionReceipt {
    MessageCenterSubmissionReceipt(
      kind: pending.feedbackID == nil ? "feedback" : "reply",
      id: feedback.id, requestID: pending.requestID)
  }
}

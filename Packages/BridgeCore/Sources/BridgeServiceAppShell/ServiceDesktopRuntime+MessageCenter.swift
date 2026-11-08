import AppKit
import BridgeDesktopUI
import Foundation
import UniformTypeIdentifiers

extension BridgeServiceAppModel {
  func startMessageCenter() {
    guard registration.supportsAutomaticRecovery else { return }
    let names: [Notification.Name] = [
      NSApplication.didBecomeActiveNotification,
      NSApplication.didResignActiveNotification,
      NSWindow.didBecomeKeyNotification,
      NSWindow.didResignKeyNotification,
      NSWindow.didMiniaturizeNotification,
      NSWindow.didDeminiaturizeNotification,
      NSWindow.willCloseNotification,
    ]
    for name in names {
      let observer = NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.updateMessageCenterVisibility() }
      }
      messageCenterVisibilityObservers.append(observer)
    }
    messageCenterState = messageCenter.state
    messageCenter.start()
    updateMessageCenterVisibility()
  }

  func stopMessageCenter() {
    guard !messageCenterVisibilityObservers.isEmpty else { return }
    for observer in messageCenterVisibilityObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    messageCenterVisibilityObservers.removeAll()
    messageCenter.stop()
  }

  private func updateMessageCenterVisibility() {
    guard !stopped, let application = NSApp else { return }
    let hasVisibleWindow = application.windows.contains { $0.isVisible && !$0.isMiniaturized }
    messageCenter.setForegroundVisible(application.isActive && hasVisibleWindow)
  }

  func chooseMessageCenterAttachment(feedbackID: String?) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      let panel = NSOpenPanel()
      panel.title = "添加截图"
      panel.canChooseFiles = true
      panel.canChooseDirectories = false
      panel.allowsMultipleSelection = true
      panel.allowedContentTypes =
        [.png, .jpeg] + [UTType(filenameExtension: "webp")].compactMap { $0 }
      let accepted = await withCheckedContinuation { continuation in
        panel.begin { continuation.resume(returning: $0 == .OK) }
      }
      guard accepted, !self.stopped else { return }
      self.messageCenter.addAttachments(paths: panel.urls.map(\.path), feedbackID: feedbackID)
    }
  }

  func openMessageCenterAttachment(id: String, feedbackID: String) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let url = try await self.messageCenter.downloadAttachment(id: id, feedbackID: feedbackID)
        guard NSWorkspace.shared.open(url) else {
          self.postToast("无法打开截图", symbol: "exclamationmark.triangle", tone: .warning)
          return
        }
      } catch {
        self.postToast(
          "无法打开截图：\(error.localizedDescription)", symbol: "exclamationmark.triangle", tone: .warning
        )
      }
    }
  }
}

extension BridgeDesktopCommandRouter {
  static func handleMessageCenter(
    _ envelope: BridgeDesktopCommandEnvelope, model: BridgeServiceAppModel
  ) {
    let payload = envelope.payload
    let center = model.messageCenter
    switch envelope.command {
    case .messageCenterRefresh:
      center.refresh()
    case .messageCenterLoadMore:
      center.loadMoreNotices()
    case .messageCenterSetVisible:
      break
    case .messageCenterMarkRead:
      guard let kind = payload.kind, ["notice", "feedback"].contains(kind),
        let id = validatedID(payload.value, maximumBytes: 128)
      else { return }
      center.markRead(kind: kind, id: id)
    case .messageCenterMarkAllRead:
      center.markAllRead()
    case .messageCenterSubmitFeedback:
      guard let category = payload.kind, ["bug", "suggestion", "other"].contains(category),
        let body = BridgeDesktopCommandValue.nonBlankText(payload.input, maximumUTF8Bytes: 65_536)
      else { return }
      center.submitFeedback(category: category, body: body)
    case .messageCenterReply:
      guard let id = validatedID(payload.feedbackID, maximumBytes: 128),
        let body = BridgeDesktopCommandValue.nonBlankText(payload.input, maximumUTF8Bytes: 65_536)
      else { return }
      center.reply(feedbackID: id, body: body)
    case .messageCenterSelectAttachments:
      model.chooseMessageCenterAttachment(feedbackID: payload.feedbackID)
    case .messageCenterRemoveAttachment:
      guard let id = validatedID(payload.value, maximumBytes: 128) else { return }
      center.removeAttachment(id: id, feedbackID: payload.feedbackID)
    case .messageCenterPreviewAttachment:
      guard let id = validatedID(payload.value, maximumBytes: 128),
        let url = center.attachmentURL(id: id, feedbackID: payload.feedbackID)
      else { return }
      if !NSWorkspace.shared.open(url) {
        model.postToast("无法打开截图", symbol: "exclamationmark.triangle", tone: .warning)
      }
    case .messageCenterOpenAttachment:
      guard let id = validatedID(payload.value, maximumBytes: 128),
        let feedbackID = validatedID(payload.feedbackID, maximumBytes: 128)
      else { return }
      model.openMessageCenterAttachment(id: id, feedbackID: feedbackID)
    default:
      break
    }
  }
}

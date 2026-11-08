#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import BridgeServiceAppCore
  import Foundation

  extension CodexBridgeDesktopApplication {
    static var messageCenter: MessageCenterController?
    static var messageCenterState: MessageCenterState?
    static var messageCenterRevision: UInt64 = 0

    static func startMessageCenter() {
      guard messageCenter == nil else { return }
      let center = MessageCenterController(
        currentVersion: appUpdateState?.currentVersion ?? "0.0.0",
        platform: DesktopPlatformHost.platform.rawValue,
        onChange: { state in
          messageCenterState = state
          messageCenterRevision &+= 1
        }
      )
      messageCenter = center
      messageCenterState = center.state
      messageCenterRevision &+= 1
      center.start()
    }

    static func handleMessageCenter(
      _ envelope: BridgeDesktopCommandEnvelope, feedback: WindowsDesktopFeedbackStore
    ) {
      guard let center = messageCenter else { return }
      let payload = envelope.payload
      let feedbackID = BridgeDesktopCommandValue.nonEmpty(payload.feedbackID, maximumUTF8Bytes: 128)
      if payload.feedbackID != nil && feedbackID == nil { return }
      switch envelope.command {
      case .messageCenterRefresh:
        center.refresh()
      case .messageCenterLoadMore:
        center.loadMoreNotices()
      case .messageCenterSetVisible:
        #if os(Linux)
          if let visible = payload.enabled { center.setForegroundVisible(visible) }
        #endif
      case .messageCenterMarkRead:
        guard let kind = payload.kind, ["notice", "feedback"].contains(kind),
          let id = BridgeDesktopCommandValue.nonEmpty(payload.value, maximumUTF8Bytes: 128)
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
        guard let feedbackID,
          let body = BridgeDesktopCommandValue.nonBlankText(payload.input, maximumUTF8Bytes: 65_536)
        else { return }
        center.reply(feedbackID: feedbackID, body: body)
      case .messageCenterSelectAttachments:
        DesktopPlatformHost.chooseImageFile(title: "选择反馈截图") { path in
          Task { @MainActor in
            guard let path, let center = messageCenter else { return }
            center.addAttachments(paths: [path], feedbackID: feedbackID)
          }
        }
      case .messageCenterRemoveAttachment:
        guard let id = BridgeDesktopCommandValue.nonEmpty(payload.value, maximumUTF8Bytes: 128)
        else {
          return
        }
        center.removeAttachment(id: id, feedbackID: feedbackID)
      case .messageCenterPreviewAttachment:
        guard let id = BridgeDesktopCommandValue.nonEmpty(payload.value, maximumUTF8Bytes: 128),
          let url = center.attachmentURL(id: id, feedbackID: feedbackID)
        else { return }
        onUI { DesktopPlatformHost.openLocalImage(url) }
      case .messageCenterOpenAttachment:
        guard let id = BridgeDesktopCommandValue.nonEmpty(payload.value, maximumUTF8Bytes: 128),
          let feedbackID
        else { return }
        Task { @MainActor in
          do {
            let url = try await center.downloadAttachment(id: id, feedbackID: feedbackID)
            onUI { DesktopPlatformHost.openLocalImage(url) }
          } catch {
            feedback.postAlert("无法打开截图：\(error.localizedDescription)")
          }
        }
      default:
        break
      }
    }
  }
#endif

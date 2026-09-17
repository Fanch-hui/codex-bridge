#if os(Windows)
  import BridgeDesktopUI

  @MainActor
  final class WindowsDesktopFeedbackStore {
    private var sequence: UInt64 = 0
    private(set) var current: BridgeDesktopFeedback?

    func postToast(
      _ message: String,
      title: String = "操作已完成",
      tone: BridgeDesktopStatusTone = .success
    ) {
      post(kind: .toast, tone: tone, title: title, message: message)
    }

    func postAlert(_ message: String, title: String = "操作失败") {
      post(kind: .alert, tone: .error, title: title, message: message)
    }

    func dismiss(id: String) {
      guard current?.id == id else { return }
      current = nil
    }

    private func post(
      kind: BridgeDesktopFeedbackKind,
      tone: BridgeDesktopStatusTone,
      title: String,
      message: String
    ) {
      sequence &+= 1
      current = BridgeDesktopFeedback(
        id: "windows-feedback-\(sequence)",
        kind: kind,
        tone: tone,
        title: title,
        message: message
      )
    }
  }
#endif

import BridgeServiceAppCore
import Combine

@MainActor
final class DesktopConversationObservation {
  private weak var conversation: TaskConversationModel?
  private var subscription: AnyCancellable?
  private var pendingUpdate: Task<Void, Never>?

  func observe(_ conversation: TaskConversationModel?, onChange: @escaping @MainActor () -> Void) {
    guard self.conversation !== conversation else { return }
    subscription?.cancel()
    pendingUpdate?.cancel()
    pendingUpdate = nil
    self.conversation = conversation
    subscription = conversation?.objectWillChange.sink { [weak self] in
      MainActor.assumeIsolated {
        self?.schedule(onChange)
      }
    }
  }

  private func schedule(_ onChange: @escaping @MainActor () -> Void) {
    guard pendingUpdate == nil else { return }
    pendingUpdate = Task { @MainActor [weak self] in
      guard !Task.isCancelled, let self else { return }
      self.pendingUpdate = nil
      onChange()
    }
  }

  deinit {
    pendingUpdate?.cancel()
  }
}

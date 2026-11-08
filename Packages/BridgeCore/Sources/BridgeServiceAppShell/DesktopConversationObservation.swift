import BridgeServiceAppCore
import Combine

@MainActor
final class DesktopConversationObservation {
  private weak var conversation: TaskConversationModel?
  private var subscription: AnyCancellable?
  private let throttle = DesktopUpdateThrottle()

  func observe(_ conversation: TaskConversationModel?, onChange: @escaping @MainActor () -> Void) {
    guard self.conversation !== conversation else { return }
    subscription?.cancel()
    throttle.cancel()
    self.conversation = conversation
    subscription = conversation?.objectWillChange.sink { [weak self] in
      MainActor.assumeIsolated {
        self?.throttle.schedule(onChange)
      }
    }
  }
}

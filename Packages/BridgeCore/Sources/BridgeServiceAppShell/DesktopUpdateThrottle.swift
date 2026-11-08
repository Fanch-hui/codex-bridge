@MainActor
final class DesktopUpdateThrottle {
  /// Streamed output is rendered at a steady cadence: each update rebuilds the desktop state,
  /// so per-delta rebuilds would starve the main thread and release text in bursts.
  private static let minimumSpacing: Duration = .milliseconds(33)
  private var pending: Task<Void, Never>?
  private var lastRun: ContinuousClock.Instant?

  /// Requests made while one run is pending share it, so `action` must read current state
  /// when it runs rather than capture state at request time.
  func schedule(_ action: @escaping @MainActor () -> Void) {
    guard pending == nil else { return }
    let wait = lastRun.map { Self.minimumSpacing - $0.duration(to: .now) } ?? .zero
    pending = Task { @MainActor [weak self] in
      if wait > .zero { try? await Task.sleep(for: wait) }
      guard !Task.isCancelled, let self else { return }
      self.pending = nil
      self.lastRun = .now
      action()
    }
  }

  func cancel() {
    pending?.cancel()
    pending = nil
  }

  deinit {
    pending?.cancel()
  }
}

import Foundation

/// Wakes event readers when a new event or a state change arrives, replacing fixed-interval
/// polling. A reader captures `generation` before it evaluates its wait condition; `wait` then
/// returns at once if `notify()` ran in between, so no wakeup is lost.
final class EmbeddedDSHEventSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var current: UInt64 = 0
  private var waits: [ObjectIdentifier: Wait] = [:]

  var generation: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func notify() {
    lock.lock()
    current &+= 1
    let ready = Array(waits.values)
    waits.removeAll()
    lock.unlock()
    for wait in ready { wait.finish() }
  }

  /// Returns once `notify()` has run after `observed`, the deadline passes, or the task is cancelled.
  func wait(after observed: UInt64, until deadline: ContinuousClock.Instant) async {
    let state = Wait()
    guard register(state, after: observed) else { return }
    defer { unregister(state) }
    let timer = Task {
      try? await ContinuousClock().sleep(until: deadline)
      state.finish()
    }
    defer { timer.cancel() }
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        state.start(continuation)
      }
    } onCancel: {
      state.finish()
    }
  }

  /// Registers before the generation check can be missed; `false` means a notification already ran.
  private func register(_ state: Wait, after observed: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard current == observed else { return false }
    waits[ObjectIdentifier(state)] = state
    return true
  }

  private func unregister(_ state: Wait) {
    lock.lock()
    waits.removeValue(forKey: ObjectIdentifier(state))
    lock.unlock()
  }

  /// One suspended reader. `finish()` is sticky, so it may run before or after `start`.
  private final class Wait: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    func start(_ continuation: CheckedContinuation<Void, Never>) {
      lock.lock()
      if finished {
        lock.unlock()
        continuation.resume()
        return
      }
      self.continuation = continuation
      lock.unlock()
    }

    func finish() {
      lock.lock()
      finished = true
      let waiting = continuation
      continuation = nil
      lock.unlock()
      waiting?.resume()
    }
  }
}

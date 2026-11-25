import Foundation

package final class AsyncMutex: @unchecked Sendable {
  private let stateLock = NSLock()
  private var locked = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  package init() {}

  package func acquire() async {
    await withCheckedContinuation { continuation in
      stateLock.lock()
      if locked {
        waiters.append(continuation)
        stateLock.unlock()
        return
      }
      locked = true
      stateLock.unlock()
      continuation.resume()
    }
  }

  package func release() {
    stateLock.lock()
    let waiter = waiters.isEmpty ? nil : waiters.removeFirst()
    if waiter == nil { locked = false }
    stateLock.unlock()
    waiter?.resume()
  }
}

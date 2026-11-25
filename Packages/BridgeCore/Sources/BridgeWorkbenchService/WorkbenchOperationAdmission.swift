import Foundation

final class WorkbenchOperationAdmission: @unchecked Sendable {
  private let lock = NSLock()
  private var active = 0
  private var ordinary = 0
  private var priorityWaiters: [CheckedContinuation<Void, Never>] = []
  private var ordinaryWaiters: [CheckedContinuation<Void, Never>] = []

  func acquire(priority: Bool) async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if priority {
        priorityWaiters.append(continuation)
      } else {
        ordinaryWaiters.append(continuation)
      }
      let ready = dequeue()
      lock.unlock()
      for waiter in ready { waiter.resume() }
    }
  }

  func release(priority: Bool) {
    lock.lock()
    active -= 1
    if !priority { ordinary -= 1 }
    let ready = dequeue()
    lock.unlock()
    for waiter in ready { waiter.resume() }
  }

  private func dequeue() -> [CheckedContinuation<Void, Never>] {
    var ready: [CheckedContinuation<Void, Never>] = []
    while active < 4 {
      if !priorityWaiters.isEmpty {
        ready.append(priorityWaiters.removeFirst())
      } else if ordinary < 3, !ordinaryWaiters.isEmpty {
        ordinary += 1
        ready.append(ordinaryWaiters.removeFirst())
      } else {
        break
      }
      active += 1
    }
    return ready
  }
}

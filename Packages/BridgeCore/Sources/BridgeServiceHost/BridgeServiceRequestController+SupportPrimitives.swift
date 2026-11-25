import BridgeDomain
import Foundation

struct StreamRegistration: Sendable {
  let forwarder: Task<Void, Never>
  let subscriptionID: Int
}

final class StreamRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var registrations: [TaskID: StreamRegistration] = [:]

  func take(_ taskID: TaskID) -> StreamRegistration? {
    lock.lock()
    defer { lock.unlock() }
    return registrations.removeValue(forKey: taskID)
  }

  func take(_ taskID: TaskID, subscriptionID: Int) -> StreamRegistration? {
    lock.lock()
    defer { lock.unlock() }
    guard registrations[taskID]?.subscriptionID == subscriptionID else { return nil }
    return registrations.removeValue(forKey: taskID)
  }

  @discardableResult
  func install(taskID: TaskID, registration: StreamRegistration) -> StreamRegistration? {
    lock.lock()
    let previous = registrations.updateValue(registration, forKey: taskID)
    lock.unlock()
    return previous
  }

  func takeAll() -> [TaskID: StreamRegistration] {
    lock.lock()
    defer { lock.unlock() }
    let active = registrations
    registrations.removeAll(keepingCapacity: false)
    return active
  }

  func count() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return registrations.count
  }
}

final class XPCRequestAdmission: @unchecked Sendable {
  private struct Waiter {
    let id: UUID
    let background: Bool
    let continuation: CheckedContinuation<Bool, Never>
  }

  private let lock = NSLock()
  private let maximumConcurrent: Int
  private let backgroundLimit: Int
  private var active = 0
  private var waiters: [Waiter] = []

  init(maximumConcurrent: Int) {
    precondition(maximumConcurrent > 0)
    self.maximumConcurrent = maximumConcurrent
    self.backgroundLimit = max(1, maximumConcurrent - 2)
  }

  func acquire(background: Bool) async -> Bool {
    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let queued = register(
          id: id, background: background, continuation: continuation)
        if queued {
          DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
            self?.removeWaiter(id)
          }
        }
      }
    } onCancel: {
      self.removeWaiter(id)
    }
  }

  private func register(
    id: UUID, background: Bool,
    continuation: CheckedContinuation<Bool, Never>
  ) -> Bool {
    lock.lock()
    if Task.isCancelled {
      lock.unlock()
      continuation.resume(returning: false)
      return false
    }
    if active < maximumConcurrent && (!background || active < backgroundLimit) {
      active += 1
      lock.unlock()
      continuation.resume(returning: true)
      return false
    }
    guard waiters.count < 32 else {
      lock.unlock()
      continuation.resume(returning: false)
      return false
    }
    waiters.append(Waiter(id: id, background: background, continuation: continuation))
    lock.unlock()
    return true
  }

  private func removeWaiter(_ id: UUID) {
    lock.lock()
    guard let index = waiters.firstIndex(where: { $0.id == id }) else {
      lock.unlock()
      return
    }
    let waiter = waiters.remove(at: index)
    lock.unlock()
    waiter.continuation.resume(returning: false)
  }

  func release() {
    lock.lock()
    active -= 1
    var ready: [Waiter] = []
    while active < maximumConcurrent && !waiters.isEmpty {
      let interactive = waiters.firstIndex(where: { !$0.background })
      guard let index = interactive ?? (active < backgroundLimit ? waiters.indices.first : nil)
      else {
        break
      }
      ready.append(waiters.remove(at: index))
      active += 1
    }
    lock.unlock()
    for waiter in ready { waiter.continuation.resume(returning: true) }
  }
}

final class XPCReplyBox: @unchecked Sendable {
  private let lock = NSLock()
  private var reply: ((Data) -> Void)?

  init(_ reply: @escaping (Data) -> Void) {
    self.reply = reply
  }

  func call(_ data: Data) {
    lock.lock()
    let callback = reply
    reply = nil
    lock.unlock()
    callback?(data)
  }
}

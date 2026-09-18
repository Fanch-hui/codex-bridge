import Foundation
@preconcurrency import NIOCore

package final class MCPHTTPRequestLease: @unchecked Sendable {
  private let lock = NSLock()
  private var admission: MCPHTTPAdmission?
  private let token: UUID

  fileprivate init(admission: MCPHTTPAdmission, token: UUID) {
    self.admission = admission
    self.token = token
  }

  package func release() {
    let admission = lock.withLock { () -> MCPHTTPAdmission? in
      let current = self.admission
      self.admission = nil
      return current
    }
    admission?.releaseRequest(token: token)
  }

  deinit { release() }
}

package final class MCPHTTPAdmission: @unchecked Sendable {
  private struct State {
    var channels: [ObjectIdentifier: any Channel] = [:]
    var activeRequestTokens: Set<UUID> = []
    var isStopping = false
    var drainWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    var indefiniteDrainWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  }

  private let lock = NSLock()
  private let maximumConnections: Int
  private let maximumActiveRequests: Int
  private var state = State()

  package init(maximumConnections: Int, maximumActiveRequests: Int) {
    self.maximumConnections = maximumConnections
    self.maximumActiveRequests = maximumActiveRequests
  }

  package func register(_ channel: any Channel) -> Bool {
    lock.withLock {
      guard !state.isStopping, state.channels.count < maximumConnections else { return false }
      state.channels[ObjectIdentifier(channel)] = channel
      return true
    }
  }

  package func unregister(_ channel: any Channel) {
    _ = lock.withLock {
      state.channels.removeValue(forKey: ObjectIdentifier(channel))
    }
  }

  package func admitRequest() -> MCPHTTPRequestLease? {
    lock.withLock {
      guard
        !state.isStopping,
        state.activeRequestTokens.count < maximumActiveRequests
      else { return nil }
      let token = UUID()
      state.activeRequestTokens.insert(token)
      return MCPHTTPRequestLease(admission: self, token: token)
    }
  }

  fileprivate func releaseRequest(token: UUID) {
    let waiters = lock.withLock {
      () -> (
        bool: [CheckedContinuation<Bool, Never>],
        indefinite: [CheckedContinuation<Void, Never>]
      ) in
      guard state.activeRequestTokens.remove(token) != nil else { return ([], []) }
      guard state.activeRequestTokens.isEmpty else { return ([], []) }
      let current = (
        bool: Array(state.drainWaiters.values),
        indefinite: Array(state.indefiniteDrainWaiters.values)
      )
      state.drainWaiters.removeAll(keepingCapacity: false)
      state.indefiniteDrainWaiters.removeAll(keepingCapacity: false)
      return current
    }
    for waiter in waiters.bool { waiter.resume(returning: true) }
    for waiter in waiters.indefinite { waiter.resume() }
  }

  package func beginStopping() {
    lock.withLock { state.isStopping = true }
  }

  package func resetAfterStop() {
    let waiters = lock.withLock {
      () -> (
        bool: [CheckedContinuation<Bool, Never>],
        indefinite: [CheckedContinuation<Void, Never>]
      ) in
      state.isStopping = false
      state.activeRequestTokens.removeAll(keepingCapacity: false)
      let current = (
        bool: Array(state.drainWaiters.values),
        indefinite: Array(state.indefiniteDrainWaiters.values)
      )
      state.drainWaiters.removeAll(keepingCapacity: false)
      state.indefiniteDrainWaiters.removeAll(keepingCapacity: false)
      return current
    }
    for waiter in waiters.bool { waiter.resume(returning: true) }
    for waiter in waiters.indefinite { waiter.resume() }
  }

  package func waitForRequestDrain() async {
    if lock.withLock({ state.activeRequestTokens.isEmpty }) { return }
    await withCheckedContinuation { continuation in
      let resumeNow = lock.withLock { () -> Bool in
        guard !state.activeRequestTokens.isEmpty else { return true }
        let waiterID = UUID()
        state.indefiniteDrainWaiters[waiterID] = continuation
        return false
      }
      if resumeNow { continuation.resume() }
    }
  }

  /// Waits for all admitted requests to finish, but returns after the bounded
  /// shutdown window even if a handler ignores cancellation.
  package func waitForRequestDrain(timeout: Duration) async -> Bool {
    if lock.withLock({ state.activeRequestTokens.isEmpty }) { return true }
    let waiterID = UUID()
    let drained = await withCheckedContinuation { continuation in
      let resumeNow = lock.withLock { () -> Bool in
        guard !state.activeRequestTokens.isEmpty else { return true }
        state.drainWaiters[waiterID] = continuation
        return false
      }
      if resumeNow {
        continuation.resume(returning: true)
      } else {
        Task { [weak self] in
          try? await Task.sleep(for: timeout)
          self?.timeoutDrainWaiter(waiterID)
        }
      }
    }
    return drained
  }

  private func timeoutDrainWaiter(_ waiterID: UUID) {
    let waiter = lock.withLock {
      state.drainWaiters.removeValue(forKey: waiterID)
    }
    waiter?.resume(returning: false)
  }

  package func metrics() -> MCPHTTPMetrics {
    lock.withLock {
      MCPHTTPMetrics(
        activeConnections: state.channels.count,
        activeRequests: state.activeRequestTokens.count
      )
    }
  }

  package func activeChannels() -> [any Channel] {
    lock.withLock { Array(state.channels.values) }
  }
}

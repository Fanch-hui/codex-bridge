import Foundation

public enum ModelGatewayAdmissionError: Error, Equatable, Sendable {
  case stopped
  case queueFull
  case queueTimedOut
}

/// Holds capacity until the upstream operation has actually returned, including cancellation cleanup.
public actor ModelGatewayRequestScheduler {
  private struct Waiter {
    let id: UUID
    let account: String
    let limit: Int
    let continuation: CheckedContinuation<Void, any Error>
    let timeout: Task<Void, Never>
  }

  private let maximumConcurrent: Int
  private let maximumQueued: Int
  private let queueTimeout: Duration
  private var active: [String: Int] = [:]
  private var activeCount = 0
  private var waiters: [Waiter] = []
  private var accepting = true

  public init(
    maximumConcurrent: Int = 8, maximumQueued: Int = 32, queueTimeout: Duration = .seconds(30)
  ) {
    precondition(maximumConcurrent > 0 && maximumQueued >= 0 && queueTimeout > .zero)
    self.maximumConcurrent = maximumConcurrent
    self.maximumQueued = maximumQueued
    self.queueTimeout = queueTimeout
  }

  public func withPermit<T: Sendable>(
    account: String, accountLimit: Int = 2,
    operation: @Sendable () async throws -> T
  ) async throws -> T {
    precondition(!account.isEmpty && accountLimit > 0)
    try await acquire(account: account, limit: accountLimit)
    defer { release(account: account) }
    try Task.checkCancellation()
    return try await operation()
  }

  public func stopAccepting() {
    accepting = false
    let queued = waiters
    waiters.removeAll()
    for waiter in queued {
      waiter.timeout.cancel()
      waiter.continuation.resume(throwing: ModelGatewayAdmissionError.stopped)
    }
  }

  public func resumeAccepting() { accepting = true }

  public func counts() -> (active: Int, queued: Int) { (activeCount, waiters.count) }

  private func acquire(account: String, limit: Int) async throws {
    try Task.checkCancellation()
    guard accepting else { throw ModelGatewayAdmissionError.stopped }
    if canStart(account: account, limit: limit),
      !waiters.contains(where: { $0.account == account })
    {
      occupy(account: account)
      return
    }
    guard waiters.count < maximumQueued else { throw ModelGatewayAdmissionError.queueFull }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        let timeout = Task { [weak self, queueTimeout] in
          do { try await Task.sleep(for: queueTimeout) } catch { return }
          await self?.remove(id, error: ModelGatewayAdmissionError.queueTimedOut)
        }
        waiters.append(
          Waiter(
            id: id, account: account, limit: limit, continuation: continuation, timeout: timeout))
      }
    } onCancel: {
      Task { await self.remove(id, error: CancellationError()) }
    }
  }

  private func canStart(account: String, limit: Int) -> Bool {
    activeCount < maximumConcurrent && active[account, default: 0] < limit
  }

  private func occupy(account: String) {
    activeCount += 1
    active[account, default: 0] += 1
  }

  private func release(account: String) {
    activeCount -= 1
    if active[account] == 1 {
      active.removeValue(forKey: account)
    } else {
      active[account, default: 0] -= 1
    }
    while accepting,
      let index = waiters.firstIndex(where: {
        canStart(account: $0.account, limit: $0.limit)
      })
    {
      let waiter = waiters.remove(at: index)
      waiter.timeout.cancel()
      occupy(account: waiter.account)
      waiter.continuation.resume()
    }
  }

  private func remove(_ id: UUID, error: any Error) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.timeout.cancel()
    waiter.continuation.resume(throwing: error)
  }
}

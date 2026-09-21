import Foundation

public final class ServiceStateChangeHub: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

  public init() {}

  public func subscribe() -> AsyncStream<Void> {
    let id = UUID()
    let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    lock.lock()
    continuations[id] = pair.continuation
    lock.unlock()
    pair.continuation.onTermination = { [weak self] _ in self?.remove(id) }
    return pair.stream
  }

  public func publish() {
    lock.lock()
    let active = Array(continuations.values)
    lock.unlock()
    for continuation in active { continuation.yield(()) }
  }

  private func remove(_ id: UUID) {
    lock.lock()
    continuations[id] = nil
    lock.unlock()
  }
}

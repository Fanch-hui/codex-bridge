import Foundation

public struct IPCServiceStateChanged: Encodable, Sendable {
  public let event = "service_state_changed"
  public init() {}
}

final class ServiceChangeStreamHub: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

  func subscribe() -> AsyncStream<Void> {
    let id = UUID()
    let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    lock.lock()
    continuations[id] = pair.continuation
    lock.unlock()
    pair.continuation.onTermination = { [weak self] _ in self?.remove(id) }
    return pair.stream
  }

  func push(_ payload: Data) {
    guard payload.count <= 128,
      let value = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
      value["event"] as? String == "service_state_changed"
    else { return }
    lock.lock()
    let active = Array(continuations.values)
    lock.unlock()
    for continuation in active { continuation.yield(()) }
  }

  func clear() {
    lock.lock()
    let active = Array(continuations.values)
    continuations.removeAll()
    lock.unlock()
    for continuation in active { continuation.finish() }
  }

  private func remove(_ id: UUID) {
    lock.lock()
    continuations[id] = nil
    lock.unlock()
  }
}

extension BridgeServiceClient {
  public func serviceChanges() -> AsyncStream<Void> { serviceChangeHub.subscribe() }
}

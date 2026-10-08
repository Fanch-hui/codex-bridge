import Foundation

/// Bridges the serialized process output callback to a bounded asynchronous consumer.
public final class ProcessFrameDelivery: @unchecked Sendable {
  public let stream: AsyncThrowingStream<Data, any Error>
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let condition = NSCondition()
  private var finished = false
  private var acceptsBackpressure = true

  public init(capacity: Int) {
    let pair = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(max(1, capacity))
    )
    stream = pair.stream
    continuation = pair.continuation
    continuation.onTermination = { [weak self] _ in self?.stopWaiting() }
  }

  /// The caller must serialize producers and must not hold its parser lock while waiting.
  @discardableResult
  public func yield(_ frame: Data) -> Bool {
    while !isFinished {
      switch continuation.yield(frame) {
      case .enqueued:
        return true
      case .dropped:
        condition.lock()
        guard !finished, acceptsBackpressure else {
          condition.unlock()
          return false
        }
        _ = condition.wait(until: Date(timeIntervalSinceNow: 0.002))
        condition.unlock()
      case .terminated:
        stopWaiting()
        return false
      @unknown default:
        stopWaiting()
        return false
      }
    }
    return false
  }

  /// Shutdown stops waiting while still accepting output that fits during the EOF grace period.
  public func disableBackpressure() {
    condition.lock()
    acceptsBackpressure = false
    condition.broadcast()
    condition.unlock()
  }

  public func finish(throwing error: (any Error)? = nil) {
    stopWaiting()
    continuation.finish(throwing: error)
  }

  private var isFinished: Bool {
    condition.lock()
    defer { condition.unlock() }
    return finished
  }

  private func stopWaiting() {
    condition.lock()
    finished = true
    condition.broadcast()
    condition.unlock()
  }
}

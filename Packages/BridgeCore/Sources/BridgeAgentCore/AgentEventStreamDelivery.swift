import Foundation

/// Keeps bounded stream delivery ordered while the consumer catches up.
public actor AgentEventStreamDelivery<Element: Sendable> {
  private enum YieldResult { case enqueued, dropped, terminated }
  private let yield: @Sendable (Element) -> YieldResult
  private var nextTicket: UInt64 = 0
  private var currentTicket: UInt64 = 0
  private var terminated = false

  public init(_ continuation: AsyncStream<Element>.Continuation) {
    yield = { element in
      switch continuation.yield(element) {
      case .enqueued: .enqueued
      case .dropped: .dropped
      case .terminated: .terminated
      @unknown default: .terminated
      }
    }
  }

  public init(_ continuation: AsyncThrowingStream<Element, any Error>.Continuation) {
    yield = { element in
      switch continuation.yield(element) {
      case .enqueued: .enqueued
      case .dropped: .dropped
      case .terminated: .terminated
      @unknown default: .terminated
      }
    }
  }

  public var hasPendingDelivery: Bool { nextTicket != currentTicket && !terminated }

  public func enqueue(_ element: Element) async -> Bool {
    guard !terminated else { return false }
    let ticket = nextTicket
    nextTicket += 1
    while !terminated {
      if ticket == currentTicket {
        switch yield(element) {
        case .enqueued:
          currentTicket += 1
          return true
        case .terminated:
          terminated = true
          return false
        case .dropped:
          break
        }
      }
      // Cancellation of the producing task must not discard terminal evidence.
      // Finishing the stream wakes delivery on the next bounded retry.
      await withCheckedContinuation { continuation in
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(2)) {
          continuation.resume()
        }
      }
    }
    return false
  }
}

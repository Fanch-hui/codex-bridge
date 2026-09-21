import Foundation

/// A body-free sample emitted at conversation presentation boundaries.
///
/// The recorder is inert unless a host installs a sink, so normal desktop
/// operation does not retain a history or add work to the hot path.
public struct ConversationPerformanceSample: Sendable {
  public enum Stage: String, Sendable {
    case conversationPushMerge
    case desktopStateBuild
    case desktopStateEncode
  }

  public let stage: Stage
  public let duration: Duration
  public let byteCount: Int
  public let queueDepth: Int
  public let entryCount: Int

  public init(
    stage: Stage,
    duration: Duration,
    byteCount: Int = 0,
    queueDepth: Int = 0,
    entryCount: Int = 0
  ) {
    self.stage = stage
    self.duration = duration
    self.byteCount = byteCount
    self.queueDepth = queueDepth
    self.entryCount = entryCount
  }
}

/// Optional host-side hook for measuring p50/p95/p99 presentation latency.
/// The hook receives metadata only; conversation text is never passed here.
public final class ConversationPerformanceRecorder: @unchecked Sendable {
  public static let shared = ConversationPerformanceRecorder()

  private let lock = NSLock()
  private var sink: (@Sendable (ConversationPerformanceSample) -> Void)?

  public init() {}

  public func setSink(
    _ sink: (@Sendable (ConversationPerformanceSample) -> Void)?
  ) {
    lock.withLock { self.sink = sink }
  }

  public func record(_ sample: ConversationPerformanceSample) {
    let sink = lock.withLock { self.sink }
    sink?(sample)
  }
}

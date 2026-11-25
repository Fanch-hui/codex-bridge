import Foundation

struct TunnelReconnectBackoff {
  private let initialDelays: [Duration]
  private var index = 0
  private var previous: Duration

  init(_ initialDelays: [Duration]) {
    self.initialDelays = initialDelays
    previous = initialDelays.last ?? .zero
  }

  mutating func next() -> Duration? {
    guard !initialDelays.isEmpty else { return nil }
    if index < initialDelays.count {
      defer { index += 1 }
      return initialDelays[index]
    }
    previous = min(previous * 2, .seconds(60))
    return previous
  }
}

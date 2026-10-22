import Foundation

final class TunnelStartupDiagnostics: @unchecked Sendable {
  enum Event: String {
    case start
    case doctorLaunchRequested = "doctor_launch_requested"
    case doctorSpawned = "doctor_spawned"
    case doctorExited = "doctor_exited"
    case runLaunchRequested = "run_launch_requested"
    case runSpawned = "run_spawned"
    case readinessStarted = "readiness_started"
    case health
    case ready
    case readinessTimedOut = "readiness_timed_out"
    case startFailed = "start_failed"
    case startCancelled = "start_cancelled"
    case stopRequested = "stop_requested"
    case terminationRequested = "termination_requested"
    case terminationSent = "termination_sent"
    case terminationNotSent = "termination_not_sent"
    case terminationEscalated = "termination_escalated"
    case terminationWaitTimedOut = "termination_wait_timed_out"
    case processExited = "process_exited"
    case pollStarted = "poll_started"
    case pollCompleted = "poll_completed"
    case pollTimedOut = "poll_timed_out"
    case pollFailed = "poll_failed"
    case pollerStarted = "poller_started"
    case pollerStopped = "poller_stopped"
    case pollerRecovered = "poller_recovered"
    case proxyPollAdjusted = "proxy_poll_adjusted"
  }

  private let lock = NSLock()
  private let startedAt = ContinuousClock.now
  private let attempt = UUID().uuidString
  private var events: [String] = []
  private var pollAttempt: Int64 = 0
  private var lastHealth: [String: Int64]?

  func record(_ event: Event, fields: [String: Int64] = [:]) {
    let line = lock.withLock {
      let elapsed = Self.milliseconds(startedAt.duration(to: .now))
      let values = fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }
      let line =
        ([
          "[TunnelStartup]", "attempt=\(attempt)", "elapsed_ms=\(elapsed)",
          "event=\(event.rawValue)",
        ] + values).joined(separator: " ")
      if events.count == 128 { events.removeFirst() }
      events.append(line)
      return line
    }
    NSLog("%@", line)
  }

  func recordHealth(localReady: Bool, pollObserved: Bool, pollFresh: Bool) {
    let fields: [String: Int64] = [
      "local_ready": localReady ? 1 : 0,
      "poll_observed": pollObserved ? 1 : 0,
      "poll_fresh": pollFresh ? 1 : 0,
    ]
    let changed = lock.withLock {
      guard lastHealth != fields else { return false }
      lastHealth = fields
      return true
    }
    if changed { record(.health, fields: fields) }
  }

  func recordReadiness(timeout: Duration, deadline: ContinuousClock.Instant) {
    record(
      .readinessStarted,
      fields: [
        "timeout_ms": Self.milliseconds(timeout),
        "deadline_elapsed_ms": Self.milliseconds(startedAt.duration(to: deadline)),
      ])
  }

  func recordHelperLine(_ line: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      let message = object["msg"] as? String
    else { return }
    let event: Event
    switch message {
    case "poll cycle started": event = .pollStarted
    case "poll cycle complete": event = .pollCompleted
    case "poll timed out; backing off": event = .pollTimedOut
    case "poll failed; backing off": event = .pollFailed
    case "poller started": event = .pollerStarted
    case "poller stopped": event = .pollerStopped
    case "poller recovered; polling operational": event = .pollerRecovered
    case "control-plane proxy closed long poll; lowering future poll timeout":
      event = .proxyPollAdjusted
    default: return
    }
    let currentPoll = lock.withLock {
      if event == .pollStarted { pollAttempt += 1 }
      return pollAttempt
    }
    var fields = ["poll_attempt": currentPoll]
    for name in [
      "limit", "commands_polled", "commands_enqueued", "retry_in_ms", "poll_timeout_ms",
      "poll_deadline_ms", "status_code", "observed_disconnect_ms", "attempted_poll_timeout_ms",
      "learned_poll_timeout_ms",
    ] {
      guard let number = object[name] as? NSNumber,
        String(cString: number.objCType) != "c",
        number.doubleValue.isFinite,
        (0...1_000_000_000_000).contains(number.doubleValue),
        number.doubleValue == Double(number.int64Value)
      else { continue }
      fields[name] = number.int64Value
    }
    record(event, fields: fields)
  }

  func snapshot() -> String {
    lock.withLock { events.joined(separator: "\n") }
  }

  static func milliseconds(_ duration: Duration) -> Int64 {
    let parts = duration.components
    return parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
  }
}

struct TunnelHelperDiagnosticFilter {
  let diagnostics: TunnelStartupDiagnostics
  private var line = Data()
  private var discardingLine = false

  init(diagnostics: TunnelStartupDiagnostics) {
    self.diagnostics = diagnostics
  }

  mutating func append(_ data: Data) {
    // Raw helper DEBUG records can include credentials, URLs and request content.
    // Only complete, bounded JSON records reach the numeric event projection.
    for byte in data {
      if byte == 0x0A {
        finish()
      } else if !discardingLine {
        if line.count < 64 * 1024 {
          line.append(byte)
        } else {
          line.removeAll(keepingCapacity: true)
          discardingLine = true
        }
      }
    }
  }

  mutating func finish() {
    if !discardingLine, !line.isEmpty { diagnostics.recordHelperLine(line) }
    line.removeAll(keepingCapacity: true)
    discardingLine = false
  }
}

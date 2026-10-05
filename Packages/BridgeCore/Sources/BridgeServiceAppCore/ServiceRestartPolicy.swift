/// Result of an attempt to make the background service pipe reachable.
public enum ServiceLaunchOutcome: Equatable, Sendable {
  /// A service pipe accepted connections (already running or freshly
  /// launched).
  case ready
  /// The service executable could not be created.
  case launchFailed(systemError: Int?)
  /// The service exited before its pipe accepted connections.
  case exitedDuringStartup(exitCode: Int?)
  /// The service stayed alive but never listened within the readiness
  /// window.
  case readinessTimeout

  public var isReady: Bool {
    if case .ready = self { return true }
    return false
  }
}

/// Pure decision logic that keeps a crashing background service from being
/// relaunched in a tight loop. The shell records each launch outcome and asks
/// the policy whether another attempt is currently allowed: the cooldown
/// doubles per consecutive failure up to a ceiling, and after a configured
/// number of consecutive failures the circuit opens and further automatic
/// launches are blocked until the policy is reset. Time is supplied by the
/// caller so the decisions stay deterministic and unit-testable.
public struct ServiceRestartPolicy: Equatable, Sendable {
  public struct Configuration: Equatable, Sendable {
    /// Cooldown applied after the first failed launch.
    public let initialBackoff: Duration
    /// Upper bound for the doubling backoff sequence.
    public let maximumBackoff: Duration
    /// Consecutive failures after which automatic launches are blocked.
    public let maximumConsecutiveFailures: Int

    public init(
      initialBackoff: Duration = .seconds(2),
      maximumBackoff: Duration = .seconds(60),
      maximumConsecutiveFailures: Int = 3
    ) {
      self.initialBackoff = initialBackoff
      self.maximumBackoff = maximumBackoff
      self.maximumConsecutiveFailures = maximumConsecutiveFailures
    }
  }

  public enum LaunchDecision: Equatable, Sendable {
    /// A launch may proceed now.
    case allowed
    /// The cooldown is still running; retry after the remaining duration.
    case deferred(for: Duration)
    /// Automatic launches are blocked until the policy is reset.
    case circuitOpen
  }

  public let configuration: Configuration
  public private(set) var consecutiveLaunchFailures: Int = 0
  /// Cooldown in effect after the most recent failure, if any.
  public private(set) var pendingBackoff: Duration?

  public init(configuration: Configuration = Configuration()) {
    self.configuration = configuration
  }

  /// - Parameter elapsedSinceLastAttempt: time since the shell last tried
  ///   to launch the service, or `nil` when no attempt has been made yet.
  public func decision(elapsedSinceLastAttempt: Duration?) -> LaunchDecision {
    guard consecutiveLaunchFailures < configuration.maximumConsecutiveFailures else {
      return .circuitOpen
    }
    guard let pendingBackoff, let elapsedSinceLastAttempt else { return .allowed }
    guard elapsedSinceLastAttempt < pendingBackoff else { return .allowed }
    return .deferred(for: pendingBackoff - elapsedSinceLastAttempt)
  }

  /// Doubles the cooldown after a failed launch attempt, saturating at
  /// `maximumBackoff`.
  public mutating func recordLaunchFailure() {
    consecutiveLaunchFailures += 1
    var backoff = pendingBackoff ?? configuration.initialBackoff
    if pendingBackoff != nil {
      backoff = backoff + backoff
      if backoff > configuration.maximumBackoff {
        backoff = configuration.maximumBackoff
      }
    }
    pendingBackoff = backoff
  }

  /// Clears the failure history. Used both when the service is confirmed
  /// reachable and for user-driven retries, so one explicit user action
  /// restores automatic launch attempts after an open circuit.
  public mutating func reset() {
    consecutiveLaunchFailures = 0
    pendingBackoff = nil
  }
}

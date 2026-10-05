import Foundation

@MainActor
public final class ServiceConnectionCoordinator {
  public enum Result: Equatable, Sendable {
    case connected
    case connectionFailed
    case launchFailed(ServiceLaunchOutcome)
    case blocked(ServiceRestartPolicy.LaunchDecision)
    case inProgress
  }

  public private(set) var restartPolicy: ServiceRestartPolicy
  public private(set) var isConnecting = false
  private var lastLaunchAttemptAt: Date?
  private let now: () -> Date

  public init(
    configuration: ServiceRestartPolicy.Configuration = .init(),
    now: @escaping () -> Date = Date.init
  ) {
    restartPolicy = ServiceRestartPolicy(configuration: configuration)
    self.now = now
  }

  public func reset() {
    restartPolicy.reset()
  }

  public func connect(
    shouldContinue: () -> Bool = { true },
    probe: @MainActor () async -> Bool,
    launch: @MainActor () async -> ServiceLaunchOutcome,
    handshake: @MainActor () async -> Bool
  ) async -> Result {
    guard !isConnecting else { return .inProgress }
    isConnecting = true
    defer { isConnecting = false }

    let serviceAvailable = await probe()
    guard shouldContinue(), !Task.isCancelled else { return .connectionFailed }
    if !serviceAvailable {
      let elapsed = lastLaunchAttemptAt.map { Duration.seconds(now().timeIntervalSince($0)) }
      let decision = restartPolicy.decision(elapsedSinceLastAttempt: elapsed)
      guard decision == .allowed else { return .blocked(decision) }
      lastLaunchAttemptAt = now()
      let outcome = await launch()
      guard shouldContinue(), !Task.isCancelled else { return .connectionFailed }
      guard outcome.isReady else {
        restartPolicy.recordLaunchFailure()
        return .launchFailed(outcome)
      }
    }

    guard await handshake(), shouldContinue(), !Task.isCancelled else { return .connectionFailed }
    restartPolicy.reset()
    return .connected
  }
}

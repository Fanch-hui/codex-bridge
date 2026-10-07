import BridgeSecurity
import BridgeServiceApplication
import BridgeServiceCore
import BridgeTunnel
import Foundation

public actor ServiceTunnelController {
  public static let runtimeKeyReference = SecretReference(
    rawValue: "service.tunnel-runtime-key"
  )

  let settings: ServiceSettings
  let runtimeStatus: ServiceRuntimeStatus
  let secretStore: any SecretStore
  let factory: any ServiceTunnelManagerBuilding
  private let monitorInterval: Duration
  private let restartDelays: [Duration]

  var tunnelID: TunnelID?
  var httpProxy: TunnelHTTPProxy?
  private var localMCPURL: URL?
  private var localMCPHeaderSecret: String?
  private var manager: (any ServiceTunnelManaging)?
  var snapshot: ServiceTunnelSnapshot
  var enabled = false
  private var generation: UInt64 = 0
  private var monitorTask: Task<Void, Never>?
  private var restartTask: Task<Void, Never>?
  var isShutdown = false

  public init(
    settings: ServiceSettings,
    runtimeStatus: ServiceRuntimeStatus,
    secretStore: any SecretStore,
    factory: any ServiceTunnelManagerBuilding,
    monitorInterval: Duration = .seconds(2),
    restartDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
  ) {
    precondition(monitorInterval > .zero)
    self.settings = settings
    self.runtimeStatus = runtimeStatus
    self.secretStore = secretStore
    self.factory = factory
    self.monitorInterval = monitorInterval
    self.restartDelays = Array(restartDelays.prefix(5))
    snapshot = .unconfigured(helperAvailable: factory.helperAvailable())
  }

  public func bootstrap(
    localMCPURL: URL,
    localMCPHeaderSecret: String
  ) async {
    guard !isShutdown else { return }
    self.localMCPURL = localMCPURL
    self.localMCPHeaderSecret = localMCPHeaderSecret
    await loadStoredConfiguration()
    guard enabled, snapshot.configured else {
      await publish(snapshot)
      return
    }
    Task { [weak self] in
      try? await self?.startConfigured()
    }
  }

  public func pauseForMCPRestart() async {
    guard !isShutdown else { return }
    await stopCurrent(publishStopped: false)
  }

  public func localMCPDidChange(
    _ localMCPURL: URL,
    localMCPHeaderSecret: String
  ) async {
    guard !isShutdown else { return }
    let changed =
      self.localMCPURL != localMCPURL || self.localMCPHeaderSecret != localMCPHeaderSecret
    self.localMCPURL = localMCPURL
    self.localMCPHeaderSecret = localMCPHeaderSecret
    guard enabled, snapshot.configured else {
      await publish(snapshot)
      return
    }
    if changed || snapshot.lifecycle == .stopped || snapshot.lifecycle == .failed {
      Task { [weak self] in
        try? await self?.startConfigured()
      }
    }
  }

  public func status() async -> ServiceTunnelSnapshot {
    if let manager {
      await refresh(manager: manager, scheduleRestart: false)
    }
    return snapshot
  }

  public func shutdown() async {
    guard !isShutdown else { return }
    isShutdown = true
    await stopCurrent(publishStopped: false)
    let final = ServiceTunnelSnapshot(
      configured: snapshot.configured,
      enabled: enabled,
      helperAvailable: factory.helperAvailable(),
      tunnelID: tunnelID?.rawValue,
      lifecycle: .stopped,
      acceptsRemoteSubmissions: false,
      actionRequired: snapshot.actionRequired,
      httpProxy: httpProxy?.url.absoluteString
    )
    snapshot = final
    await runtimeStatus.updateTunnel(state: TunnelLifecycle.stopped.rawValue)
  }

  func startConfigured() async throws {
    let context = try configuredStartContext()
    if try await currentManagerIsUsable() { return }
    try await requireAvailableHelper(tunnelID: context.tunnelID)
    guard context.tunnelID == tunnelID, context.httpProxy == httpProxy, !isShutdown else {
      throw ServiceTunnelError.serviceStopped
    }
    let runGeneration = await prepareStart(tunnelID: context.tunnelID)
    do {
      try await launchCandidate(context: context, generation: runGeneration)
    } catch {
      await recordStartFailure(error, generation: runGeneration)
      if let serviceError = error as? ServiceTunnelError {
        throw serviceError
      }
      throw ServiceTunnelError.startFailed
    }
  }

  private typealias StartContext = (
    tunnelID: TunnelID,
    localMCPURL: URL,
    localMCPHeaderSecret: String,
    httpProxy: TunnelHTTPProxy?
  )

  private func configuredStartContext() throws -> StartContext {
    guard !isShutdown else { throw ServiceTunnelError.serviceStopped }
    guard let tunnelID else { throw ServiceTunnelError.notConfigured }
    guard let localMCPURL, let localMCPHeaderSecret else {
      throw ServiceTunnelError.localMCPUnavailable
    }
    return (tunnelID, localMCPURL, localMCPHeaderSecret, httpProxy)
  }

  private func currentManagerIsUsable() async throws -> Bool {
    guard let current = manager else { return false }
    switch await current.state() {
    case .ready:
      return true
    case .starting, .authenticating, .connecting:
      return try await waitForCurrentManager()
    case .stopped, .failed, .degraded:
      return false
    }
  }

  private func waitForCurrentManager() async throws -> Bool {
    let clock = ContinuousClock()
    let startupTimeout = TunnelConfiguration.defaultReadinessTimeout + .seconds(20)
    let deadline = clock.now.advanced(by: startupTimeout)
    while clock.now < deadline {
      try await Task.sleep(for: .milliseconds(200))
      guard !isShutdown, let active = manager else { return false }
      switch await active.state() {
      case .ready:
        await refresh(manager: active, scheduleRestart: true)
        return true
      case .failed, .stopped:
        return false
      case .starting, .authenticating, .connecting, .degraded:
        continue
      }
    }
    return false
  }

  private func requireAvailableHelper(tunnelID: TunnelID) async throws {
    guard factory.helperAvailable() else {
      let failure = ServiceTunnelSnapshot(
        configured: hasRuntimeKey(),
        enabled: enabled,
        helperAvailable: false,
        tunnelID: tunnelID.rawValue,
        lifecycle: .failed,
        acceptsRemoteSubmissions: false,
        actionRequired: true,
        httpProxy: httpProxy?.url.absoluteString
      )
      snapshot = failure
      await publish(failure, degradation: "The signed tunnel-client helper is unavailable.")
      throw ServiceTunnelError.helperUnavailable
    }
  }

  private func prepareStart(tunnelID: TunnelID) async -> UInt64 {
    generation &+= 1
    let runGeneration = generation
    cancelBackgroundTasks()
    let previous = manager
    manager = nil
    await previous?.stop()
    guard runGeneration == generation, !isShutdown else { return runGeneration }
    let starting = ServiceTunnelSnapshot(
      configured: true,
      enabled: enabled,
      helperAvailable: true,
      tunnelID: tunnelID.rawValue,
      lifecycle: .starting,
      acceptsRemoteSubmissions: false,
      actionRequired: false,
      httpProxy: httpProxy?.url.absoluteString
    )
    snapshot = starting
    await publish(starting)
    return runGeneration
  }

  private func launchCandidate(
    context: StartContext,
    generation runGeneration: UInt64
  ) async throws {
    guard runGeneration == generation, !isShutdown else {
      throw ServiceTunnelError.serviceStopped
    }
    let candidate = try await factory.make(
      tunnelID: context.tunnelID,
      runtimeKeyReference: Self.runtimeKeyReference,
      localMCPURL: context.localMCPURL,
      localMCPHeaderSecret: context.localMCPHeaderSecret,
      httpProxy: context.httpProxy
    )
    guard runGeneration == generation, !isShutdown else {
      await candidate.stop()
      throw ServiceTunnelError.serviceStopped
    }
    manager = candidate
    try await candidate.start()
    guard runGeneration == generation, !isShutdown else {
      await candidate.stop()
      throw ServiceTunnelError.serviceStopped
    }
    await refresh(manager: candidate, scheduleRestart: true)
    beginMonitor(generation: runGeneration)
  }

  private func recordStartFailure(_ error: any Error, generation runGeneration: UInt64) async {
    NSLog(
      "[ServiceTunnelController] Tunnel start failed: %@",
      String(describing: error)
    )
    if !(error is ServiceTunnelError), let diagnostics = await manager?.diagnostics() {
      NSLog(
        "[ServiceTunnelController] Diagnostics: stdout=%@, stderr=%@",
        diagnostics.standardOutput,
        diagnostics.standardError
      )
    }
    guard runGeneration == generation else { return }
    await failStart(candidate: manager, error: error)
  }

  private func failStart(
    candidate: (any ServiceTunnelManaging)?,
    error: any Error
  ) async {
    let diagnostics = await candidate?.diagnostics()
    await candidate?.stop()
    manager = nil
    let actionRequired = diagnostics?.actionRequired == true || Self.requiresLocalAction(error)
    let failed = ServiceTunnelSnapshot(
      configured: tunnelID != nil && hasRuntimeKey(),
      enabled: enabled,
      helperAvailable: factory.helperAvailable(),
      tunnelID: tunnelID?.rawValue,
      lifecycle: .failed,
      acceptsRemoteSubmissions: false,
      actionRequired: actionRequired,
      httpProxy: httpProxy?.url.absoluteString
    )
    snapshot = failed
    await publish(
      failed,
      degradation: actionRequired
        ? "Secure MCP Tunnel requires local action."
        : "Secure MCP Tunnel could not start."
    )
    if !actionRequired, enabled, !isShutdown, !restartDelays.isEmpty {
      beginRestart(generation: generation)
    }
  }

  private func beginMonitor(generation: UInt64) {
    guard monitorTask == nil else { return }
    monitorTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: self?.monitorInterval ?? .seconds(2))
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        await self?.inspect(generation: generation)
      }
    }
  }

  private func inspect(generation: UInt64) async {
    guard generation == self.generation, enabled, let manager else { return }
    await refresh(manager: manager, scheduleRestart: true)
  }

  private func refresh(
    manager: any ServiceTunnelManaging,
    scheduleRestart: Bool
  ) async {
    let observedGeneration = generation
    let lifecycle = await manager.state()
    let diagnostics = await manager.diagnostics()
    let acceptsRemote = await manager.acceptsRemoteSubmissions()
    guard observedGeneration == generation else { return }
    let current = ServiceTunnelSnapshot(
      configured: tunnelID != nil && hasRuntimeKey(),
      enabled: enabled,
      helperAvailable: factory.helperAvailable(),
      tunnelID: tunnelID?.rawValue,
      lifecycle: lifecycle,
      acceptsRemoteSubmissions: acceptsRemote && !diagnostics.actionRequired,
      actionRequired: diagnostics.actionRequired,
      httpProxy: httpProxy?.url.absoluteString
    )
    snapshot = current
    await publish(current, degradation: Self.degradation(for: current))

    guard scheduleRestart, lifecycle == .failed, enabled else { return }
    monitorTask?.cancel()
    monitorTask = nil
    if diagnostics.actionRequired || restartDelays.isEmpty {
      return
    }
    beginRestart(generation: generation)
  }

  private func beginRestart(generation: UInt64) {
    guard restartTask == nil else { return }
    restartTask = Task { [weak self] in
      await self?.restart(generation: generation)
    }
  }

  private func restart(generation: UInt64) async {
    var backoff = TunnelReconnectBackoff(restartDelays)
    while let delay = backoff.next() {
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      guard generation == self.generation, enabled, !isShutdown,
        let tunnelID, let localMCPURL, let localMCPHeaderSecret
      else {
        return
      }

      let previous = manager
      manager = nil
      await previous?.stop()
      do {
        let candidate = try await factory.make(
          tunnelID: tunnelID,
          runtimeKeyReference: Self.runtimeKeyReference,
          localMCPURL: localMCPURL,
          localMCPHeaderSecret: localMCPHeaderSecret,
          httpProxy: httpProxy
        )
        guard generation == self.generation, enabled, !isShutdown else {
          await candidate.stop()
          return
        }
        manager = candidate
        try await candidate.start()
        guard generation == self.generation, enabled, !isShutdown else {
          await candidate.stop()
          return
        }
        let lifecycle = await candidate.state()
        let diagnostics = await candidate.diagnostics()
        let accepts = await candidate.acceptsRemoteSubmissions()
        guard lifecycle == .ready, accepts, !diagnostics.actionRequired else {
          await candidate.stop()
          manager = nil
          if diagnostics.actionRequired {
            await markRestartFailure(actionRequired: true)
            restartTask = nil
            return
          }
          continue
        }
        restartTask = nil
        await refresh(manager: candidate, scheduleRestart: false)
        beginMonitor(generation: generation)
        return
      } catch {
        guard generation == self.generation, !Task.isCancelled else { return }
        let failed = manager
        let diagnostics = await failed?.diagnostics()
        await failed?.stop()
        guard generation == self.generation, enabled, !isShutdown else { return }
        manager = nil
        if diagnostics?.actionRequired == true || Self.requiresLocalAction(error) {
          await markRestartFailure(actionRequired: true)
          restartTask = nil
          return
        }
      }
    }
  }

  private func markRestartFailure(actionRequired: Bool) async {
    let failed = ServiceTunnelSnapshot(
      configured: tunnelID != nil && hasRuntimeKey(),
      enabled: enabled,
      helperAvailable: factory.helperAvailable(),
      tunnelID: tunnelID?.rawValue,
      lifecycle: .failed,
      acceptsRemoteSubmissions: false,
      actionRequired: actionRequired,
      httpProxy: httpProxy?.url.absoluteString
    )
    snapshot = failed
    await publish(
      failed,
      degradation: "Secure MCP Tunnel requires local action."
    )
  }

  func stopCurrent(publishStopped: Bool) async {
    generation &+= 1
    let stoppedGeneration = generation
    cancelBackgroundTasks()
    let current = manager
    manager = nil
    await current?.stop()
    guard publishStopped, stoppedGeneration == generation else { return }
    let stopped = ServiceTunnelSnapshot(
      configured: tunnelID != nil && hasRuntimeKey(),
      enabled: enabled,
      helperAvailable: factory.helperAvailable(),
      tunnelID: tunnelID?.rawValue,
      lifecycle: .stopped,
      acceptsRemoteSubmissions: false,
      actionRequired: false,
      httpProxy: httpProxy?.url.absoluteString
    )
    snapshot = stopped
    await publish(stopped)
  }

  private func cancelBackgroundTasks() {
    monitorTask?.cancel()
    restartTask?.cancel()
    monitorTask = nil
    restartTask = nil
  }

  private static func degradation(for snapshot: ServiceTunnelSnapshot) -> String? {
    switch snapshot.lifecycle {
    case .ready, .stopped, .starting, .authenticating, .connecting:
      nil
    case .degraded:
      "Secure MCP Tunnel remote readiness is degraded."
    case .failed:
      snapshot.actionRequired
        ? "Secure MCP Tunnel requires local action."
        : "Secure MCP Tunnel failed."
    }
  }

  private static func requiresLocalAction(_ error: any Error) -> Bool {
    if error is TunnelHelperError { return true }
    if let error = error as? TunnelManagerError {
      switch error {
      case .invalidRuntimeKey:
        return true
      case .doctorFailed, .alreadyRunning, .lifecycleBusy, .helperUnavailable, .launchFailed,
        .readinessTimedOut, .helperExited, .processTimedOut, .cleanupFailed, .stopped:
        return false
      }
    }
    return error is ServiceTunnelError
  }
}

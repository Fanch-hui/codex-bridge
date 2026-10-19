import BridgeSecurity
import Foundation

public actor TunnelManager {
  public typealias Now = @Sendable () -> Date

  private struct RunContext: Sendable {
    let id: UUID
    let name: String
    let root: TunnelDirectoryHandle
    let run: TunnelDirectoryHandle
    let directory: URL
    let healthURLFile: URL

    var hasExpectedIdentity: Bool {
      root.contains(name: name, directory: run)
    }
  }

  private let configuration: TunnelConfiguration
  private let secretStore: any SecretStore
  private let helperVerifier: TunnelHelperVerifier
  private let launcher = TunnelProcessLauncher()
  private let healthClient = LoopbackHealthClient()
  private let now: Now
  private let outputLimit = 128 * 1024
  private var lifecycle: TunnelLifecycle = .stopped
  private var process: TunnelSpawnedProcess?
  private var runContext: RunContext?
  private var monitor: Task<Void, Never>?
  private var doctorInProgress = false
  private var doctorProcess: TunnelSpawnedProcess?
  private var startupDiagnostics: TunnelStartupDiagnostics?
  private var lastDiagnostics = TunnelDiagnostics(
    standardOutput: "",
    standardError: "",
    wasTruncated: false,
    actionRequired: false
  )

  public init(
    configuration: TunnelConfiguration,
    secretStore: any SecretStore,
    helperVerifier: TunnelHelperVerifier = TunnelHelperVerifier(),
    now: @escaping Now = Date.init
  ) {
    self.configuration = configuration
    self.secretStore = secretStore
    self.helperVerifier = helperVerifier
    self.now = now
  }

  public func state() -> TunnelLifecycle { lifecycle }

  public func acceptsRemoteSubmissions() -> Bool {
    lifecycle == .ready && !lastDiagnostics.actionRequired
  }

  public func diagnostics() -> TunnelDiagnostics {
    captureDiagnostics()
    return lastDiagnostics.appendingStartupTrace(startupDiagnostics)
  }

  public func doctor() async throws -> TunnelDoctorReport {
    guard lifecycle == .stopped || lifecycle == .failed else {
      throw TunnelManagerError.lifecycleBusy
    }
    guard !doctorInProgress else { throw TunnelManagerError.lifecycleBusy }
    startupDiagnostics = configuration.startupDiagnosticsEnabled ? TunnelStartupDiagnostics() : nil
    startupDiagnostics?.record(.start)
    doctorInProgress = true
    defer { doctorInProgress = false }
    let verifiedHelper = try helperVerifier.verify(
      executable: configuration.helperExecutable,
      expectedSHA256: configuration.expectedHelperSHA256
    )
    let key = try loadRuntimeKey()
    let context = try prepareRunContext()
    var cleanupFinished = false
    defer {
      if !cleanupFinished, !cleanup(context) { recordCleanupFailure() }
    }
    let child = try spawn(
      verifiedHelper: verifiedHelper,
      arguments: helperArguments(command: "doctor", context: context) + ["--json"],
      key: key,
      context: context
    )
    doctorProcess = child
    defer {
      if doctorProcess === child { doctorProcess = nil }
    }
    let exit: TunnelChildExit
    do {
      exit = try await waitForExit(child, timeout: configuration.processTimeout)
    } catch {
      await terminate(child)
      captureDiagnostics(from: child)
      throw error
    }
    startupDiagnostics?.record(.doctorExited, fields: ["exit_code": Int64(exit.code)])
    let diagnostics = TunnelDiagnostics.capture(child)
    guard
      exit.code == 0
        || TunnelDoctorCompatibility.acceptsNoAuthDoctorCompatibility(
          exitCode: exit.code,
          standardOutput: diagnostics.standardOutput
        )
    else {
      throw TunnelManagerError.doctorFailed(
        exitCode: exit.code,
        diagnostics: diagnostics.combinedOutput
      )
    }
    let cleaned = cleanup(context)
    cleanupFinished = true
    guard cleaned else {
      recordCleanupFailure()
      throw TunnelManagerError.cleanupFailed
    }
    return TunnelDoctorReport(output: diagnostics.standardOutput)
  }

  public func start() async throws {
    guard !doctorInProgress else { throw TunnelManagerError.lifecycleBusy }
    guard lifecycle == .stopped || lifecycle == .failed else {
      throw TunnelManagerError.alreadyRunning
    }
    startupDiagnostics = configuration.startupDiagnosticsEnabled ? TunnelStartupDiagnostics() : nil
    startupDiagnostics?.record(.start)
    lifecycle = .starting
    do {
      let verifiedHelper = try helperVerifier.verify(
        executable: configuration.helperExecutable,
        expectedSHA256: configuration.expectedHelperSHA256
      )
      let key = try loadRuntimeKey()
      let context = try prepareRunContext()
      runContext = context
      lifecycle = .authenticating
      try await runDoctor(context: context, key: key, verifiedHelper: verifiedHelper)
      guard runContext?.id == context.id, lifecycle != .stopped else {
        throw TunnelManagerError.stopped
      }
      let child = try spawn(
        verifiedHelper: verifiedHelper,
        arguments: helperArguments(command: "run", context: context),
        key: key,
        context: context
      )
      process = child
      runContext = context
      try await waitUntilReady(runID: context.id)
      lifecycle = .ready
      startupDiagnostics?.record(.ready)
      beginMonitor(runID: context.id)
    } catch {
      startupDiagnostics?.record(error is CancellationError ? .startCancelled : .startFailed)
      NSLog("[TunnelManager] start failed")
      if let child = process {
        await terminate(child)
        captureDiagnostics(from: child)
      }
      if let context = runContext, !cleanup(context) { recordCleanupFailure() }
      if lifecycle != .stopped { lifecycle = .failed }
      process = nil
      runContext = nil
      throw error
    }
  }

  public func stop() async {
    startupDiagnostics?.record(.stopRequested)
    monitor?.cancel()
    monitor = nil
    let child = process
    let doctorChild = doctorProcess
    let context = runContext
    process = nil
    doctorProcess = nil
    runContext = nil
    lifecycle = .stopped
    if let child {
      await terminate(child)
      captureDiagnostics(from: child)
    }
    if let doctorChild, doctorChild !== child {
      await terminate(doctorChild)
      captureDiagnostics(from: doctorChild)
    }
    if let context, !cleanup(context) {
      recordCleanupFailure()
      lifecycle = .failed
    }
  }

  private func runDoctor(
    context: RunContext,
    key: Data,
    verifiedHelper: TunnelVerifiedHelper
  ) async throws {
    let child = try spawn(
      verifiedHelper: verifiedHelper,
      arguments: helperArguments(command: "doctor", context: context) + ["--json"],
      key: key,
      context: context
    )
    process = child
    let exit = try await waitForExit(child, timeout: configuration.processTimeout)
    startupDiagnostics?.record(.doctorExited, fields: ["exit_code": Int64(exit.code)])
    guard process === child, runContext?.id == context.id, lifecycle != .stopped else {
      throw TunnelManagerError.stopped
    }
    if process === child { process = nil }
    let output = TunnelDiagnostics.capture(child)
    lastDiagnostics = output
    guard
      exit.code == 0
        || TunnelDoctorCompatibility.acceptsNoAuthDoctorCompatibility(
          exitCode: exit.code,
          standardOutput: output.standardOutput
        )
    else {
      NSLog("[TunnelManager] doctor failed")
      throw TunnelManagerError.doctorFailed(
        exitCode: exit.code,
        diagnostics: output.combinedOutput
      )
    }
  }

  private func spawn(
    verifiedHelper: TunnelVerifiedHelper,
    arguments: [String],
    key: Data,
    context: RunContext
  ) throws -> TunnelSpawnedProcess {
    let keyText = String(decoding: key, as: UTF8.self)
    let urlText = configuration.localMCPURL.absoluteString
    let headerSecret = configuration.localMCPHeaderSecret
    guard context.hasExpectedIdentity else { throw TunnelManagerError.launchFailed }
    let isRun = arguments.first == "run"
    startupDiagnostics?.record(isRun ? .runLaunchRequested : .doctorLaunchRequested)
    let child = try launcher.spawn(
      verifiedHelper: verifiedHelper,
      helperVerifier: helperVerifier,
      arguments: arguments,
      runtimeKey: key,
      localMCPHeaderSecret: Data(headerSecret.utf8),
      runtimeDirectory: context.directory,
      sensitiveValues: [keyText, urlText, headerSecret, configuration.tunnelID.rawValue],
      outputLimit: outputLimit,
      startupDiagnostics: isRun ? startupDiagnostics : nil
    )
    startupDiagnostics?.record(
      isRun ? .runSpawned : .doctorSpawned, fields: ["pid": Int64(child.pid)])
    return child
  }

  private func waitUntilReady(runID: UUID) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: configuration.readinessTimeout)
    startupDiagnostics?.recordReadiness(timeout: configuration.readinessTimeout, deadline: deadline)
    while clock.now < deadline {
      guard runContext?.id == runID, let child = process else {
        throw TunnelManagerError.stopped
      }
      if let exit = child.pollExit() {
        startupDiagnostics?.record(.processExited, fields: ["exit_code": Int64(exit.code)])
        captureDiagnostics(from: child)
        throw TunnelManagerError.helperExited(exitCode: exit.code)
      }
      captureDiagnostics(from: child)
      let health = healthState(child: child)
      if health.pollFresh { lifecycle = .connecting }
      if health.ready, !lastDiagnostics.actionRequired { return }
      try await Task.sleep(for: .milliseconds(200))
    }
    NSLog("[TunnelManager] readiness timed out")
    startupDiagnostics?.record(.readinessTimedOut)
    throw TunnelManagerError.readinessTimedOut
  }

  private func beginMonitor(runID: UUID) {
    monitor = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: self?.configuration.healthInterval ?? .seconds(5))
        guard !Task.isCancelled else { return }
        await self?.inspectRun(runID: runID)
      }
    }
  }

  private func inspectRun(runID: UUID) {
    guard runContext?.id == runID, let child = process else { return }
    if let exit = child.pollExit() {
      startupDiagnostics?.record(.processExited, fields: ["exit_code": Int64(exit.code)])
      captureDiagnostics(from: child)
      NSLog("[TunnelManager] tunnel client exited")
      lifecycle = .failed
      if let context = runContext, !cleanup(context) { recordCleanupFailure() }
      process = nil
      runContext = nil
      monitor?.cancel()
      monitor = nil
      return
    }
    captureDiagnostics(from: child)
    lifecycle =
      healthState(child: child).ready && !lastDiagnostics.actionRequired ? .ready : .degraded
  }

  private func healthState(child: TunnelSpawnedProcess) -> (pollFresh: Bool, ready: Bool) {
    guard let context = runContext, context.hasExpectedIdentity else { return (false, false) }
    do {
      let snapshot = try healthClient.snapshot(
        urlFileDirectory: context.run,
        expectedPeerPID: child.pid
      )
      guard let timestamp = snapshot.pollTimestamp, timestamp > 0 else {
        startupDiagnostics?.recordHealth(
          localReady: snapshot.isReady, pollObserved: false, pollFresh: false)
        return (false, false)
      }
      let age = now().timeIntervalSince1970 - timestamp
      let fresh = age >= -5 && age <= configuration.metricsFreshness.timeInterval
      startupDiagnostics?.recordHealth(
        localReady: snapshot.isReady, pollObserved: true, pollFresh: fresh)
      return (fresh, fresh && snapshot.isReady)
    } catch {
      startupDiagnostics?.recordHealth(localReady: false, pollObserved: false, pollFresh: false)
      NSLog("[TunnelManager] health check failed")
      return (false, false)
    }
  }

  private func loadRuntimeKey() throws -> Data {
    let key = try secretStore.load(configuration.runtimeKeyReference)
    guard let keyText = String(data: key, encoding: .utf8) else {
      throw TunnelManagerError.invalidRuntimeKey
    }
    let bytes = Array(keyText.utf8)
    guard
      keyText == keyText.trimmingCharacters(in: .whitespacesAndNewlines),
      !bytes.isEmpty,
      bytes.count <= 16 * 1024,
      bytes.allSatisfy({ (0x21...0x7E).contains($0) })
    else {
      throw TunnelManagerError.invalidRuntimeKey
    }
    return key
  }

  private func prepareRunContext() throws -> RunContext {
    let root = try TunnelDirectoryHandle(existingRoot: configuration.runtimeDirectory)
    let id = UUID()
    let name = "r-\(id.uuidString.prefix(12))"
    let run = try TunnelDirectoryHandle(creating: name, in: root)
    let directory = URL(fileURLWithPath: run.path, isDirectory: true)
    let healthURLFile = directory.appendingPathComponent(LoopbackHealthClient.urlFileName)
    let context = RunContext(
      id: id,
      name: name,
      root: root,
      run: run,
      directory: directory,
      healthURLFile: healthURLFile
    )
    var succeeded = false
    defer {
      if !succeeded { _ = cleanup(context) }
    }
    try run.createDirectory(name: "codex-home")
    succeeded = true
    return context
  }

  private func helperArguments(command: String, context: RunContext) -> [String] {
    TunnelHelperArguments.make(
      command: command,
      configuration: configuration,
      runtimeDirectory: context.directory,
      healthURLFile: context.healthURLFile
    )
  }

  private func waitForExit(
    _ child: TunnelSpawnedProcess,
    timeout: Duration
  ) async throws -> TunnelChildExit {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if let exit = child.pollExit() { return exit }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw TunnelManagerError.processTimedOut
  }

  private func terminate(_ child: TunnelSpawnedProcess) async {
    startupDiagnostics?.record(.terminationRequested, fields: ["pid": Int64(child.pid)])
    guard child.beginTermination() else {
      startupDiagnostics?.record(.terminationNotSent)
      _ = await exits(child, within: configuration.processTimeout + .seconds(2))
      return
    }
    startupDiagnostics?.record(.terminationSent)
    if await exits(child, within: configuration.processTimeout) { return }
    child.escalateTermination()
    startupDiagnostics?.record(.terminationEscalated)
    _ = await exits(child, within: .seconds(2))
  }

  private func cleanup(_ context: RunContext) -> Bool {
    guard context.hasExpectedIdentity else { return false }
    do {
      for name in [
        "observed.json", LoopbackHealthClient.urlFileName, "tunnel.pid",
      ] {
        try context.run.removeEntry(name: name)
      }
      try context.run.removeEntry(name: "codex-home", directory: true)
      guard context.root.contains(name: context.name, directory: context.run) else { return false }
      try context.root.removeEntry(name: context.name, directory: true)
      return true
    } catch {
      return false
    }
  }

  private func exits(_ child: TunnelSpawnedProcess, within duration: Duration) async -> Bool {
    await exit(child, within: duration) != nil
  }

  private func exit(
    _ child: TunnelSpawnedProcess,
    within duration: Duration
  ) async -> TunnelChildExit? {
    let exit = await Task.detached { () -> TunnelChildExit? in
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: duration)
      while clock.now < deadline {
        if let exit = child.pollExit() { return exit }
        try? await Task.sleep(for: .milliseconds(50))
      }
      return child.pollExit()
    }.value
    if let exit {
      startupDiagnostics?.record(.processExited, fields: ["exit_code": Int64(exit.code)])
    } else {
      startupDiagnostics?.record(.terminationWaitTimedOut)
    }
    return exit
  }

  private func captureDiagnostics() {
    guard let process else { return }
    captureDiagnostics(from: process)
  }

  private func captureDiagnostics(from child: TunnelSpawnedProcess) {
    lastDiagnostics = TunnelDiagnostics.capture(child)
  }

  private func recordCleanupFailure() {
    lastDiagnostics = lastDiagnostics.recordingCleanupFailure()
  }
}

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    let parts = components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
  }
}

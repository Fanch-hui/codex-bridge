import BridgeACP
import BridgeAgentCore
import Foundation

public actor EmbeddedDSHRuntime {
  public typealias Handler = @Sendable (String, ACPJSONValue) async throws -> ACPJSONValue
  public typealias EventHandler = @Sendable (EmbeddedDSHEvent) async -> Void

  private let configuration: EmbeddedDSHRuntimeConfiguration
  private let handler: Handler
  private let onEvent: EventHandler
  private var client: EmbeddedDSHClient?
  private var trackedClients: [UInt64: EmbeddedDSHClient] = [:]
  private var opening: Task<EmbeddedDSHClient, any Error>?
  private var closing: Task<Void, Never>?
  private var recovering: Task<Bool, Never>?
  private var generation: UInt64 = 0
  private var stopped = false
  private var lastFailure: EmbeddedDSHRuntimeError?

  public init(
    configuration: EmbeddedDSHRuntimeConfiguration,
    handler: @escaping Handler,
    onEvent: @escaping EventHandler
  ) {
    self.configuration = configuration
    self.handler = handler
    self.onEvent = onEvent
  }

  public func call(
    action: String, payload: ACPJSONValue = .object([:]), timeout: Duration? = nil
  ) async throws -> ACPJSONValue {
    let client = try await activeClient()
    return try await client.request(
      action: action, payload: payload, timeout: timeout ?? configuration.requestTimeout)
  }

  /// A failed host is restarted only on an explicit request, avoiding replay of unknown actions.
  public func restart() async throws {
    await stop()
    guard await confirmedStopped() else { throw EmbeddedDSHRuntimeError.processTreeStillRunning }
    stopped = false
    lastFailure = nil
    _ = try await activeClient()
  }

  public func shutdown() async {
    await stop()
  }

  /// Reconciles a host recorded before this service started, without starting a new host.
  public func recoverPreviousHost() async -> Bool {
    await confirmedStopped()
  }

  /// True only after the recorded host and all managed descendants have exited.
  public func confirmedStopped() async -> Bool {
    if let closing { await closing.value }
    if let recovering {
      let confirmed = await recovering.value
      return confirmed && client == nil && opening == nil
    }
    guard client == nil, opening == nil,
      let dataRoot = try? configuration.validatedDataRoot()
    else { return false }
    let tracked = trackedClients
    let task = Task {
      for client in tracked.values {
        guard await client.confirmedStopped() else { return false }
      }
      if !tracked.isEmpty { return EmbeddedDSHHostRecord.clear(in: dataRoot) }
      return await EmbeddedDSHHostRecord.recover(in: dataRoot)
    }
    recovering = task
    let confirmed = await task.value
    if confirmed {
      for attempt in tracked.keys { trackedClients.removeValue(forKey: attempt) }
    }
    recovering = nil
    return confirmed && client == nil && opening == nil
  }

  private func activeClient() async throws -> EmbeddedDSHClient {
    if let closing { await closing.value }
    if let recovering, !(await recovering.value) {
      throw EmbeddedDSHRuntimeError.processTreeStillRunning
    }
    guard !stopped else { throw EmbeddedDSHRuntimeError.stopped }
    if let lastFailure { throw lastFailure }
    if let client { return client }
    if let opening {
      let attempt = generation
      let started = try await opening.value
      guard attempt == generation, !stopped else { throw EmbeddedDSHRuntimeError.stopped }
      return started
    }

    generation &+= 1
    let attempt = generation
    let configuration = configuration
    let handler = handler
    let onEvent = onEvent
    let task = Task { [weak self] in
      try await Self.launch(
        configuration: configuration, handler: handler, onEvent: onEvent,
        onCreated: { [weak self] client in await self?.track(client, generation: attempt) },
        onFailure: { [weak self] error in await self?.didFail(error, generation: attempt) }
      )
    }
    opening = task
    do {
      let started = try await task.value
      guard attempt == generation, !stopped else {
        _ = await started.close()
        throw EmbeddedDSHRuntimeError.stopped
      }
      opening = nil
      client = started
      return started
    } catch {
      if attempt == generation {
        opening = nil
        if !(error is CancellationError) {
          let failure = Self.mapError(error)
          // No caller action is sent before the startup status handshake completes.
          lastFailure = failure == .startupTimedOut ? nil : failure
        }
      }
      throw error
    }
  }

  private func track(_ client: EmbeddedDSHClient, generation: UInt64) {
    trackedClients[generation] = client
  }

  private func didFail(_ error: EmbeddedDSHRuntimeError, generation: UInt64) async {
    guard self.generation == generation, !stopped else { return }
    client = nil
    lastFailure = error
    await onEvent(
      EmbeddedDSHEvent(
        type: "runtime.failed", payload: .object(["message": .string(error.localizedDescription)])))
  }

  private func stop() async {
    if let closing {
      await closing.value
      return
    }
    stopped = true
    generation &+= 1
    let current = client
    let starting = opening
    client = nil
    opening = nil
    starting?.cancel()
    let task = Task {
      if let current {
        _ = try? await current.request(
          action: "runtime.shutdown", payload: .object([:]), timeout: .seconds(2))
        _ = await current.close()
      }
      if let starting, let started = try? await starting.value {
        _ = await started.close()
      }
    }
    closing = task
    await task.value
    closing = nil
  }

  private static func launch(
    configuration: EmbeddedDSHRuntimeConfiguration,
    handler: @escaping Handler,
    onEvent: @escaping EventHandler,
    onCreated: @escaping @Sendable (EmbeddedDSHClient) async -> Void,
    onFailure: @escaping EmbeddedDSHClient.FailureHandler
  ) async throws -> EmbeddedDSHClient {
    let dataRoot = try configuration.validatedDataRoot()
    let root = try configuration.resolveResourceRoot()
    let resources = try await Task.detached(priority: .utility) {
      try EmbeddedDSHRuntimeResources.load(root: root)
    }.value
    try Task.checkCancellation()
    do {
      try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    } catch { throw EmbeddedDSHRuntimeError.invalidConfiguration }
    guard await EmbeddedDSHHostRecord.recover(in: dataRoot) else {
      throw EmbeddedDSHRuntimeError.processTreeStillRunning
    }
    let record = EmbeddedDSHHostRecord()
    try record.save(in: dataRoot)
    let environment = EmbeddedDSHRuntimeEnvironment.make(
      nodePath: resources.node.canonicalPath, dataRoot: dataRoot)
    let transport: ACPProcessTransport
    do {
      transport = try ACPProcessTransport.launch(
        configuration: ACPProcessTransportConfiguration(
          argv: [
            resources.node.canonicalPath, resources.entry.canonicalPath, "--home", dataRoot.path,
          ],
          workingDirectory: dataRoot.path,
          environment: environment,
          maximumFrameBytes: 32 * 1_024 * 1_024,
          maximumLifetime: .seconds(10 * 365 * 24 * 60 * 60),
          inputEOFGracePeriod: .seconds(2),
          processGroupName: record.groupName
        ))
    } catch { throw EmbeddedDSHRuntimeError.launchFailed }

    let client = EmbeddedDSHClient(
      transport: transport, callback: handler, eventHandler: onEvent, failureHandler: onFailure)
    await onCreated(client)
    do {
      guard let identity = transport.processIdentity else {
        throw EmbeddedDSHRuntimeError.launchFailed
      }
      try record.running(identity: identity).save(in: dataRoot)
      try resources.validateEntrypoints()
      await client.start()
      let status = try await client.request(
        action: "status", payload: .object([:]), timeout: configuration.requestTimeout)
      guard status["ready"]?.boolValue == true else {
        throw EmbeddedDSHRuntimeError.protocolViolation
      }
      try Task.checkCancellation()
      return client
    } catch {
      _ = await client.close()
      if (error as? EmbeddedDSHRuntimeError) == .requestTimedOut {
        throw EmbeddedDSHRuntimeError.startupTimedOut
      }
      throw error
    }
  }

  private static func mapError(_ error: any Error) -> EmbeddedDSHRuntimeError {
    if let error = error as? EmbeddedDSHRuntimeError { return error }
    return .launchFailed
  }
}

private enum EmbeddedDSHRuntimeEnvironment {
  static func make(nodePath: String, dataRoot: URL) -> [String: String] {
    let source = ProcessInfo.processInfo.environment
    let allowed = [
      "HOME", "PATH", "LANG", "LC_ALL", "LC_CTYPE", "TZ", "TMPDIR", "TMP", "TEMP",
      "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
      "http_proxy", "https_proxy", "all_proxy", "no_proxy",
      "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS", "XDG_RUNTIME_DIR",
      "DBUS_SESSION_BUS_ADDRESS",
    ]
    var result: [String: String] = [:]
    for key in allowed {
      guard let value = source[key], !value.isEmpty, !value.contains("\0") else { continue }
      result[key] = value
    }
    AgentProviderEnvironment.applyWindowsSystemEnvironment(to: &result, from: source)
    result["PATH"] = AgentProviderEnvironment.executableSearchPath(
      executablePath: nodePath, source: result)
    result["DSH_HOME"] = dataRoot.path
    return result
  }
}

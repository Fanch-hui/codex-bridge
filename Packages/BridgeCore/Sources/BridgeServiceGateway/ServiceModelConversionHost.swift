import BridgeACP
import BridgeAgentCore
import BridgeProviderRuntime
import Foundation

/// Keeps one protocol helper process resident and shared by every converting request. A request
/// holds a lease for its own request ID only; the process outlives it. The helper is launched on
/// first use, relaunched on the next request after it exits, and closed with the gateway.
actor ServiceModelConversionHost {
  typealias Launcher = @Sendable () async throws -> ProviderHostClient

  private var current: ProviderHostClient?
  private var resolving: Task<ProviderHostClient, any Error>?
  private var leases = 0
  private var stopWhenDrained = false

  /// `launch` starts the helper process; it runs only when no usable helper exists.
  func begin(launch: @escaping Launcher) async throws -> ServiceModelConversion {
    stopWhenDrained = false
    leases += 1
    do {
      return ServiceModelConversion(client: try await helper(launch), owner: self)
    } catch {
      leases -= 1
      throw error
    }
  }

  /// A request no longer needs its lease. An unhealthy helper is replaced on the next request.
  func end(_ client: ProviderHostClient, healthy: Bool) async {
    leases -= 1
    if !healthy {
      await discard(client)
    } else if leases == 0, stopWhenDrained {
      try? await stop()
    }
  }

  /// Closes the helper now when no request uses it, otherwise as soon as the last one ends. Best
  /// effort; `stop()` at shutdown still reports a helper whose exit cannot be confirmed.
  func stopWhenIdle() async {
    guard leases == 0 else {
      stopWhenDrained = true
      return
    }
    try? await stop()
  }

  /// Closes the helper and waits until its process tree has exited.
  func stop() async throws {
    stopWhenDrained = false
    if let resolving { _ = try? await resolving.value }
    guard let client = current else { return }
    guard await client.close() else { throw ProviderRuntimeError.processTreeStillRunning }
    if current === client { current = nil }
  }

  /// Joins a launch already in flight so concurrent first requests start one process.
  private func helper(_ launch: @escaping Launcher) async throws -> ProviderHostClient {
    if let resolving { return try await resolving.value }
    let task = Task { try await self.resolve(launch) }
    resolving = task
    return try await task.value
  }

  private func resolve(_ launch: Launcher) async throws -> ProviderHostClient {
    defer { resolving = nil }
    if let client = current {
      if !(await client.isClosed) { return client }
      // A new helper starts only after the previous process tree is confirmed gone.
      guard await client.close() else { throw ProviderRuntimeError.processTreeStillRunning }
      if current === client { current = nil }
    }
    let launched = try await launch()
    current = launched
    return launched
  }

  private func discard(_ client: ProviderHostClient) async {
    guard await client.close() else { return }
    if current === client { current = nil }
  }
}

extension ServiceModelConversionHost {
  /// Starts the helper after re-checking only its own executable snapshot.
  static func launchHelper(resources: ProviderRuntimeResources, directory: URL) async throws
    -> ProviderHostClient
  {
    try resources.validateProtocolExecutable()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var environment: [String: String] = [:]
    #if os(Windows)
      let inherited = ProcessInfo.processInfo.environment
      AgentProviderEnvironment.applyWindowsSystemEnvironment(to: &environment, from: inherited)
      if let windir = AgentProviderEnvironment.environmentValue("WINDIR", source: inherited),
        !windir.isEmpty, !windir.contains("\0")
      {
        environment["WINDIR"] = windir
      }
      environment["TEMP"] = directory.path
      environment["TMP"] = directory.path
    #endif
    let transport = try ACPProcessTransport.launch(
      configuration: ACPProcessTransportConfiguration(
        argv: [resources.protocolExecutable.path, "--state-dir", directory.path],
        workingDirectory: directory.path, environment: environment,
        maximumFrameBytes: 32 * 1_024 * 1_024))
    let client = ProviderHostClient(transport: transport) { _ in
      throw ProviderRuntimeError.invalidMessage
    }
    await client.start()
    return client
  }
}

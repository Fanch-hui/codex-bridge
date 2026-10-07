import BridgeSecurity
import BridgeServiceCore
import BridgeTunnel
import Foundation

extension ServiceTunnelController {
  @discardableResult
  public func configure(
    tunnelID rawTunnelID: String,
    runtimeKey rawRuntimeKey: String
  ) async throws -> ServiceTunnelSnapshot {
    guard !isShutdown else { throw ServiceTunnelError.serviceStopped }
    let tunnelID = try TunnelID(validating: rawTunnelID)
    let runtimeKey = try Self.validatedRuntimeKey(rawRuntimeKey)
    try await persist(tunnelID: tunnelID, runtimeKey: runtimeKey, enabled: true)
    self.tunnelID = tunnelID
    self.enabled = true
    snapshot = ServiceTunnelSnapshot(
      configured: true,
      enabled: true,
      helperAvailable: factory.helperAvailable(),
      tunnelID: tunnelID.rawValue,
      lifecycle: .stopped,
      acceptsRemoteSubmissions: false,
      actionRequired: false,
      httpProxy: httpProxy?.url.absoluteString
    )
    try await startConfigured()
    return snapshot
  }

  @discardableResult
  public func connect() async throws -> ServiceTunnelSnapshot {
    guard !isShutdown else { throw ServiceTunnelError.serviceStopped }
    guard tunnelID != nil, hasRuntimeKey() else {
      throw ServiceTunnelError.notConfigured
    }
    try await settings.set("1", for: .tunnelEnabled)
    enabled = true
    try await startConfigured()
    return snapshot
  }

  public func disconnect() async throws {
    guard !isShutdown else { throw ServiceTunnelError.serviceStopped }
    try await settings.set("0", for: .tunnelEnabled)
    enabled = false
    await stopCurrent(publishStopped: true)
  }

  public func clearConfiguration() async throws {
    guard !isShutdown else { throw ServiceTunnelError.serviceStopped }
    enabled = false
    await stopCurrent(publishStopped: false)
    try await settings.set(nil, for: .tunnelID)
    try await settings.set(nil, for: .tunnelEnabled)
    try await settings.set(nil, for: .tunnelHTTPProxy)
    httpProxy = nil
    do {
      try secretStore.remove(Self.runtimeKeyReference)
    } catch SecretStoreError.notFound {
    } catch {
      throw ServiceTunnelError.secretStoreUnavailable
    }
    tunnelID = nil
    snapshot = .unconfigured(helperAvailable: factory.helperAvailable())
    await publish(snapshot)
  }

  @discardableResult
  public func setHTTPProxy(_ value: String?) async throws -> ServiceTunnelSnapshot {
    guard !isShutdown else { throw ServiceTunnelError.serviceStopped }
    let proxy = try TunnelHTTPProxy.parse(value)
    guard proxy != httpProxy else { return await status() }
    try await settings.set(proxy?.url.absoluteString, for: .tunnelHTTPProxy)
    httpProxy = proxy
    await stopCurrent(publishStopped: true)
    if enabled, snapshot.configured {
      try await startConfigured()
    }
    return snapshot
  }

  func loadStoredConfiguration() async {
    let rawID: String?
    do {
      rawID = try await settings.string(for: .tunnelID)
      httpProxy = try TunnelHTTPProxy.parse(await settings.string(for: .tunnelHTTPProxy))
    } catch {
      // Keep a previously loaded identity visible when a transient settings
      // read fails during a service restart.
      guard tunnelID == nil else {
        await publish(snapshot, degradation: "The stored Tunnel configuration is unavailable.")
        return
      }
      tunnelID = nil
      enabled = false
      snapshot = ServiceTunnelSnapshot(
        configured: false,
        enabled: false,
        helperAvailable: factory.helperAvailable(),
        tunnelID: nil,
        lifecycle: .failed,
        acceptsRemoteSubmissions: false,
        actionRequired: true,
        httpProxy: httpProxy?.url.absoluteString
      )
      await publish(snapshot, degradation: "The stored Tunnel configuration is invalid.")
      return
    }

    enabled = (try? await settings.string(for: .tunnelEnabled)) == "1"
    guard let rawID else {
      tunnelID = nil
      snapshot = .unconfigured(
        helperAvailable: factory.helperAvailable(), httpProxy: httpProxy?.url.absoluteString)
      return
    }

    do {
      tunnelID = try TunnelID(validating: rawID)
    } catch {
      tunnelID = nil
      enabled = false
      snapshot = ServiceTunnelSnapshot(
        configured: false,
        enabled: false,
        helperAvailable: factory.helperAvailable(),
        tunnelID: nil,
        lifecycle: .failed,
        acceptsRemoteSubmissions: false,
        actionRequired: true,
        httpProxy: httpProxy?.url.absoluteString
      )
      await publish(snapshot, degradation: "The stored Tunnel configuration is invalid.")
      return
    }

    let configured = hasRuntimeKey()
    snapshot = ServiceTunnelSnapshot(
      configured: configured,
      enabled: enabled,
      helperAvailable: factory.helperAvailable(),
      tunnelID: rawID,
      lifecycle: configured ? .stopped : .failed,
      acceptsRemoteSubmissions: false,
      actionRequired: !configured,
      httpProxy: httpProxy?.url.absoluteString
    )
    if !configured {
      await publish(
        snapshot,
        degradation: "The stored Tunnel Runtime Key is unavailable."
      )
    }
  }

  private func persist(
    tunnelID: TunnelID,
    runtimeKey: Data,
    enabled: Bool
  ) async throws {
    let previousKey = try? secretStore.load(Self.runtimeKeyReference)
    let previousID = try? await settings.string(for: .tunnelID)
    let previousEnabled = try? await settings.string(for: .tunnelEnabled)
    do {
      try secretStore.store(runtimeKey, for: Self.runtimeKeyReference)
      try await settings.set(tunnelID.rawValue, for: .tunnelID)
      try await settings.set(enabled ? "1" : "0", for: .tunnelEnabled)
    } catch {
      if let previousKey {
        try? secretStore.store(previousKey, for: Self.runtimeKeyReference)
      } else {
        try? secretStore.remove(Self.runtimeKeyReference)
      }
      try? await settings.set(previousID ?? nil, for: .tunnelID)
      try? await settings.set(previousEnabled ?? nil, for: .tunnelEnabled)
      throw ServiceTunnelError.secretStoreUnavailable
    }
  }

  func hasRuntimeKey() -> Bool {
    guard let data = try? secretStore.load(Self.runtimeKeyReference),
      let value = String(data: data, encoding: .utf8)
    else {
      return false
    }
    return (try? Self.validatedRuntimeKey(value)) != nil
  }

  func publish(
    _ snapshot: ServiceTunnelSnapshot,
    degradation: String? = nil
  ) async {
    await runtimeStatus.updateTunnel(
      state: snapshot.lifecycle.rawValue,
      degradation: degradation
    )
  }

  private static func validatedRuntimeKey(_ value: String) throws -> Data {
    let bytes = Array(value.utf8)
    guard
      value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      !bytes.isEmpty,
      bytes.count <= 16 * 1_024,
      bytes.allSatisfy({ (0x21...0x7E).contains($0) })
    else {
      throw ServiceTunnelError.invalidRuntimeKey
    }
    return Data(bytes)
  }

}

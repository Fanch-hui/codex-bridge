import BridgeACP
import BridgeEmbeddedDSH
import BridgeServiceCore
import Foundation

/// Owns the only model adapters and account refreshers for the embedded providers.
actor ServiceExistingProviders {
  weak var workbench: ServiceEmbeddedDSHController?
  let configuration: EmbeddedDSHRuntimeConfiguration
  var runtime: EmbeddedDSHRuntime?
  var sessions: [String: String] = [:]

  init(workbench: ServiceEmbeddedDSHController, dataRoot: URL, resourceRoot: URL? = nil) {
    self.workbench = workbench
    self.configuration = EmbeddedDSHRuntimeConfiguration(
      resourceRoot: resourceRoot, dataRoot: dataRoot, providersOnly: true)
  }

  func call(_ action: String, payload: ACPJSONValue = .object([:]), timeout: Duration? = nil)
    async throws -> ACPJSONValue
  {
    let engine = engine()
    do {
      return try await engine.call(action: action, payload: payload, timeout: timeout)
    } catch {
      if await engine.confirmedStopped() {
        runtime = nil
        sessions.removeAll()
      }
      throw error
    }
  }

  func workbenchCall(_ input: ACPJSONValue) async throws -> ACPJSONValue {
    guard let action = input["action"]?.stringValue, let payload = input["payload"] else {
      throw ServiceStoreError.invalidArgument("provider.callback")
    }
    let streamID = payload["id"]?.stringValue
    if action == "provider.stream.open", let streamID,
      let sessionID = payload["options"]?["sessionId"]?.stringValue
    {
      guard payload["sessionHeader"]?.objectValue != nil, sessions[streamID] == nil else {
        throw ServiceStoreError.invalidArgument("provider.session")
      }
      sessions[streamID] = sessionID
    }
    do {
      let result = try await call(action, payload: payload)
      if let streamID,
        action == "provider.stream.cancel"
          || (action == "provider.stream.next"
            && (result["done"]?.boolValue == true
              || result["chunk"]?["type"]?.stringValue == "finish"
              || result["$providerFailure"] != nil))
      {
        sessions.removeValue(forKey: streamID)
      }
      return result
    } catch {
      if action == "provider.stream.open", let streamID { sessions.removeValue(forKey: streamID) }
      throw error
    }
  }

  func cancelGatewayStream(_ id: String) async throws {
    guard let runtime else { return }
    _ = try await runtime.callIfRunning(
      action: "gateway.stream.cancel", payload: .object(["id": .string(id)]))
  }

  func shutdown() async throws {
    guard let runtime else { return }
    await runtime.shutdown()
    guard await runtime.confirmedStopped() else {
      throw EmbeddedDSHRuntimeError.processTreeStillRunning
    }
    self.runtime = nil
    sessions.removeAll()
  }

  private func engine() -> EmbeddedDSHRuntime {
    if let runtime { return runtime }
    let engine = EmbeddedDSHRuntime(
      configuration: configuration,
      handler: { [weak self] method, payload in
        guard let self else { throw CancellationError() }
        return try await self.callback(method, payload: payload)
      },
      onEvent: { [weak self] event in
        await self?.receive(event)
      })
    runtime = engine
    return engine
  }

  private func receive(_ event: EmbeddedDSHEvent) async {
    await workbench?.receiveProviderEvent(event)
  }

  private func callback(_ method: String, payload: ACPJSONValue) async throws -> ACPJSONValue {
    guard let workbench else { throw CancellationError() }
    switch method {
    case "bridge/secret":
      return try await workbench.secret(payload)
    case "bridge/providerSession":
      guard payload["action"]?.stringValue == "confirmedResponses",
        let streamID = payload["streamID"]?.stringValue,
        let sessionID = payload["sessionID"]?.stringValue,
        sessions[streamID] == sessionID
      else { throw ServiceStoreError.invalidArgument("provider.session_scope") }
      return try await workbench.providerSession(payload)
    default:
      throw ServiceStoreError.invalidArgument("provider.callback")
    }
  }
}

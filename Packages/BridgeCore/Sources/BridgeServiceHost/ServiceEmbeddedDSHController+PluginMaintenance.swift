import BridgeACP
import BridgeEmbeddedDSH
import Foundation

enum NativePluginMutationError: Error {
  case cancelledBeforeDispatch
}

extension ServiceEmbeddedDSHController {
  func performPluginAction(_ action: String, payload: [String: ACPJSONValue]) async throws
    -> ACPJSONValue
  {
    if ["plugins.install", "plugins.update", "plugins.enable", "plugins.remove"].contains(action) {
      return try await withNativePluginMaintenance(
        prepare: {},
        operation: {
          try await self.invoke(action: action, payload: .object(payload))
        })
    }
    let id = payload["requestId"]?.stringValue
    if action == "plugins.beginInstall", let id { _ = try await startPluginMaintenance(id: id) }
    do {
      let response = try await invoke(action: action, payload: .object(payload))
      if let id,
        ["completed", "failed", "cancelled", "unknown"].contains(
          response["status"]?.stringValue ?? "")
      {
        await finishPluginMaintenance(id: id)
      }
      return response
    } catch {
      if action == "plugins.beginInstall", let id, Self.isDefinitiveNativePluginFailure(error) {
        await finishPluginMaintenance(id: id)
      }
      throw error
    }
  }

  func startPluginMaintenance(id: String) async throws -> Bool {
    try await application.beginWorkbenchMaintenance(operationID: id)
  }

  func finishPluginMaintenance(id: String) async {
    await application.finishWorkbenchMaintenance(operationID: id)
  }

  func finishAllPluginMaintenance() async {
    await application.finishAllWorkbenchMaintenance()
  }

  func withNativePluginMaintenance(
    prepare: @escaping @Sendable () async throws -> Void,
    operation: @escaping @Sendable () async throws -> ACPJSONValue
  ) async throws -> ACPJSONValue {
    let id = UUID().uuidString
    _ = try await startPluginMaintenance(id: id)
    // The service owns the mutation after admission, even if the UI request is cancelled.
    let task = Task {
      do {
        try await prepare()
      } catch {
        await self.finishPluginMaintenance(id: id)
        throw error
      }
      do {
        let result = try await operation()
        await self.finishPluginMaintenance(id: id)
        return result
      } catch {
        if Self.isDefinitiveNativePluginFailure(error) {
          await self.finishPluginMaintenance(id: id)
        }
        throw error
      }
    }
    return try await task.value
  }

  private static func isDefinitiveNativePluginFailure(_ error: Error) -> Bool {
    if error is NativePluginMutationError { return true }
    guard let runtimeError = error as? EmbeddedDSHRuntimeError else { return false }
    switch runtimeError {
    case .remote, .busy, .invalidConfiguration: return true
    default: return false
    }
  }

  func nativePluginEngine(epoch: Int) throws -> EmbeddedDSHRuntime {
    guard epoch == nativeClientEpoch, !isShuttingDown else {
      throw NativePluginMutationError.cancelledBeforeDispatch
    }
    return try engine()
  }

  func invokeNativePlugin(epoch: Int, payload: ACPJSONValue) async throws -> ACPJSONValue {
    await runtimeAdmission.acquire(priority: false)
    defer { runtimeAdmission.release(priority: false) }
    let engine = try nativePluginEngine(epoch: epoch)
    return try await engine.call(
      action: "client.rpc", payload: payload, timeout: .seconds(315_360_000))
  }
}

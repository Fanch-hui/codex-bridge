import Foundation

extension BridgeServiceClient {
  public func prepareAppUpdate() async throws -> Bool {
    do {
      let response: IPCAppUpdatePreparationResponse = try await call(
        operation: .prepareAppUpdate,
        payload: Optional<IPCMutationResponse>.none
      )
      return response.canInstall
    } catch {
      throw Self.mapAppUpdateCompatibilityError(error)
    }
  }

  public func cancelAppUpdate() async throws {
    do {
      let _: IPCMutationResponse = try await call(
        operation: .cancelAppUpdate,
        payload: Optional<IPCMutationResponse>.none
      )
    } catch {
      throw Self.mapAppUpdateCompatibilityError(error)
    }
  }

  private static func mapAppUpdateCompatibilityError(_ error: Error) -> Error {
    guard let codecError = error as? BridgeServiceIPCCodecError else { return error }
    switch codecError {
    case .requestMismatch:
      return BridgeServiceClientError.serviceRestartRequired
    case .remoteError(let remote)
    where remote.code == "invalid_request" || remote.code == "unsupported_operation":
      return BridgeServiceClientError.serviceRestartRequired
    default:
      return error
    }
  }
}

#if os(Windows)
  extension BridgeServiceClient {
    public func shutdownService() async throws -> IPCServiceShutdownResponse {
      let response: IPCServiceShutdownResponse = try await call(
        operation: .shutdownService,
        payload: Optional<IPCMutationResponse>.none
      )
      return response
    }
  }
#endif

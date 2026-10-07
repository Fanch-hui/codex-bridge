import BridgeIPC
import Foundation

@MainActor
public enum DeepSeekDesktopConnection {
  public static func perform(
    _ request: DeepSeekHarnessDesktopRequest,
    client: any BridgeServiceClientProtocol,
    launchApplication: (String) async throws -> Void
  ) async throws -> DeepSeekHarnessDesktopState {
    do {
      return try await client.manageDeepSeekHarnessDesktop(request)
    } catch BridgeServiceIPCCodecError.remoteError(let error)
      where error.code == "desktop_connector_not_ready"
      && (request.action == .connect || request.action == .pair)
    {
      let state = try await client.manageDeepSeekHarnessDesktop(
        .init(installationID: request.installationID))
      guard state.connectorInstalled else {
        throw BridgeServiceIPCCodecError.remoteError(error)
      }
      try await launchApplication(state.executablePath)
      for attempt in 0..<20 {
        try await Task.sleep(for: .milliseconds(500))
        do {
          return try await client.manageDeepSeekHarnessDesktop(request)
        } catch BridgeServiceIPCCodecError.remoteError(let failure)
          where failure.code == "desktop_connector_not_ready" && attempt < 19
        {
          continue
        }
      }
      throw BridgeServiceIPCCodecError.remoteError(error)
    }
  }
}

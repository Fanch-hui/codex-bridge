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
      let state = try await client.manageDeepSeekHarnessDesktop(request)
      if request.action == .connect || request.action == .pair {
        try await launchApplication(state.executablePath)
      }
      return state
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

  public static func waitForPairing(
    installationID: String, client: any BridgeServiceClientProtocol,
    initialState: DeepSeekHarnessDesktopState,
    interval: Duration = .seconds(1), timeout: Duration = .seconds(300),
    onUpdate: (DeepSeekHarnessDesktopState) -> Bool
  ) async throws -> DeepSeekHarnessDesktopState? {
    var state = initialState
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !state.desktop.paired, state.desktop.pairingCode != nil {
      guard ContinuousClock.now < deadline else {
        state = pairingExpired(state)
        _ = onUpdate(state)
        return state
      }
      try await Task.sleep(for: interval)
      state = try await client.manageDeepSeekHarnessDesktop(.init(installationID: installationID))
      try Task.checkCancellation()
      guard onUpdate(state) else { return nil }
    }
    return state
  }

  private static func pairingExpired(_ state: DeepSeekHarnessDesktopState)
    -> DeepSeekHarnessDesktopState
  {
    .init(
      mode: state.mode,
      desktop: .init(
        connected: state.desktop.connected, paired: false,
        profileID: state.desktop.profileID, instanceID: state.desktop.instanceID,
        protocolRevision: state.desktop.protocolRevision,
        unavailableReason: "配对等待已结束，请点击连接重新发起。", errorCode: "desktop_pairing_wait_expired"),
      executablePath: state.executablePath, connectorInstalled: state.connectorInstalled,
      canInstallConnector: state.canInstallConnector)
  }
}

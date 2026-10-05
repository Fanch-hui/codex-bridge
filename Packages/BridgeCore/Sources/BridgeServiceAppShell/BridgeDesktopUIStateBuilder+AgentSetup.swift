import BridgeDesktopUI
import BridgeIPC

extension BridgeDesktopUIStateBuilder {
  static func agentSetupState(_ value: IPCAgentSetupState) -> BridgeDesktopAgentSetupState {
    BridgeDesktopAgentSetupState(
      operationID: value.operationID, providerID: value.providerID,
      distribution: value.distribution, state: value.state, message: value.message,
      installationDirectory: value.installationDirectory, executablePath: value.executablePath,
      version: value.version, installationID: value.installationID, userAction: value.userAction,
      loginInstructions: value.loginCommand?.instructions,
      documentationURL: value.loginCommand?.documentationURL,
      canOpenLogin: value.loginCommand != nil,
      candidates: value.candidates.map {
        BridgeDesktopAgentSetupCandidate(
          installationID: $0.installationID, executablePath: $0.executablePath,
          displayName: $0.displayName)
      }
    )
  }
}

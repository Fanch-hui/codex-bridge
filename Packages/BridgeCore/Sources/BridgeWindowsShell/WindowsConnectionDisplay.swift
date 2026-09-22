#if os(Windows)
  import BridgeDesktopUI
  import Foundation

  struct WindowsConnectionDisplay: Equatable, Sendable {
    let connectionState: WindowsWorkbenchDisplay.ConnectionState
    let clientRows: [String]
    let selectedClientIndex: Int?
    let clientDetailText: String
    let endpointText: String
    let exposureRows: [String]
    let selectedExposureIndex: Int?
    let toggleTitle: String
    let toggleEnabled: Bool
    let saveExposureEnabled: Bool
    let copyConfigurationEnabled: Bool
    let rotateCredentialEnabled: Bool
    let rotateEndpointEnabled: Bool
    let statusText: String
    var clientItems: [BridgeDesktopMCPClientRow] = []
    var deepSeekHarnessMCPItems: [BridgeDesktopDeepSeekHarnessMCPRow] = []
    var tunnel: BridgeDesktopTunnelState? = nil
    var codexExecutablePath: String? = nil
    var codexResolvedExecutablePath: String? = nil
  }
#endif

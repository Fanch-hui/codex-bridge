import BridgeDesktopUI

extension BridgeDesktopUIStateBuilder {
  static func geminiCloudState(from model: BridgeServiceAppModel) -> BridgeDesktopGeminiCloudState {
    let status = model.geminiCloudStatus
    let connected = model.connectionState == .connected
    let enabled = model.mcpClients.first { $0.clientID == "google.gemini" }?.enabled == true
    return BridgeDesktopGeminiCloudState(
      hosting: status?.configuration?.hosting.rawValue ?? "sites",
      baseURL: status?.configuration?.baseURL ?? "",
      enabled: status?.configuration?.enabled ?? false,
      lifecycle: status?.lifecycle ?? "stopped",
      message: status?.message,
      lastConnectedAt: status?.lastConnectedAt,
      canConfigure: connected && enabled,
      canExport: connected && enabled
    )
  }
}

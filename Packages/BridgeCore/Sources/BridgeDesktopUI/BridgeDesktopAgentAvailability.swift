import BridgeServiceAppCore

public enum BridgeDesktopAgentAvailability: Equatable, Sendable {
  case available
  case idle
  case requiresReconnect

  public static func resolve(
    providerID: String, enabled: Bool, availability: String,
    desktop: BridgeDesktopDeepSeekHarnessDesktopState?
  ) -> Self {
    guard enabled else { return .idle }
    guard providerID == "deepseek-harness-desktop" else {
      if availability == "available" { return .available }
      return ProjectAgentPresentation.requiresReconnect(isEnabled: true, availability: availability)
        ? .requiresReconnect : .idle
    }
    if availability == "needs_review" || availability == "incompatible" {
      return .requiresReconnect
    }
    // Native readiness changes independently of the persisted installation Probe.
    guard let desktop else { return .idle }
    if desktop.connected && desktop.paired { return .available }
    switch desktop.errorCode {
    case nil, "desktop_not_running", "desktop_connector_not_ready", "desktop_pairing_required":
      return .idle
    default:
      return .requiresReconnect
    }
  }
}

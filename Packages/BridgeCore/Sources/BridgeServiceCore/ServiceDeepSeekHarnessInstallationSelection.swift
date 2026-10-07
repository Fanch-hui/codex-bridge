import BridgeAgentCore

public enum ServiceDeepSeekHarnessInstallationSelection {
  public static func desktopInstallation(
    in records: [ServiceAgentInstallationRecord], activeID: String?
  ) -> ServiceAgentInstallationRecord? {
    let desktop = records.filter { $0.providerID == .deepSeekHarnessDesktop && $0.isEnabled }
    if let activeID { return desktop.first { $0.id.rawValue == activeID } }
    return desktop.min { $0.id.rawValue < $1.id.rawValue }
  }

  public static func acpInstallation(
    in records: [ServiceAgentInstallationRecord]
  ) -> ServiceAgentInstallationRecord? {
    records.filter {
      $0.providerID == .deepSeekHarness && $0.isEnabled
        && $0.artifacts.contains(where: { $0.role == .launchConfiguration })
    }.min { $0.id.rawValue < $1.id.rawValue }
  }
}

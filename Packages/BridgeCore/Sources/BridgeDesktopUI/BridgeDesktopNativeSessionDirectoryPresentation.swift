public struct BridgeDesktopNativeSessionInstallationCandidate: Equatable, Sendable {
  public let installationID: String
  public let providerID: String
  public let displayName: String
  public let region: String?
  public let isEnabled: Bool
  public let availability: String

  public init(
    installationID: String,
    providerID: String,
    displayName: String,
    region: String?,
    isEnabled: Bool,
    availability: String
  ) {
    self.installationID = installationID
    self.providerID = providerID
    self.displayName = displayName
    self.region = region
    self.isEnabled = isEnabled
    self.availability = availability
  }
}

public enum BridgeDesktopNativeSessionDirectoryPresentation {
  public static func state(
    candidates: [BridgeDesktopNativeSessionInstallationCandidate],
    prior: BridgeDesktopNativeSessionDirectoryState?
  ) -> BridgeDesktopNativeSessionDirectoryState {
    let installations: [BridgeDesktopNativeSessionInstallation] = candidates.compactMap {
      candidate in
      guard candidate.providerID == "pi" || candidate.providerID == "qoder",
        candidate.isEnabled, candidate.availability == "available"
      else { return nil }
      return BridgeDesktopNativeSessionInstallation(
        installationID: candidate.installationID,
        providerID: candidate.providerID,
        displayName: candidate.displayName,
        region: candidate.region
      )
    }
    return BridgeDesktopNativeSessionDirectoryState(
      installations: installations,
      projectID: prior?.projectID,
      installationID: prior?.installationID,
      selectedSessionID: prior?.selectedSessionID,
      sessions: prior?.sessions ?? [],
      transcript: prior?.transcript ?? [],
      nextOffset: prior?.nextOffset,
      transcriptNextOffset: prior?.transcriptNextOffset,
      isOpen: prior?.isOpen ?? false,
      isLoading: prior?.isLoading ?? false,
      statusMessage: prior?.statusMessage,
      errorMessage: prior?.errorMessage
    )
  }
}

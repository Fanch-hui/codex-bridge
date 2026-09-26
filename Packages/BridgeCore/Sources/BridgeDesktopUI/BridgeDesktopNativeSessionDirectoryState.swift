import BridgeAgentCore
import Foundation

public struct BridgeDesktopNativeSessionInstallation: Codable, Equatable, Sendable {
  public let installationID: String
  public let providerID: String
  public let displayName: String
  public let region: String?

  public init(
    installationID: String, providerID: String, displayName: String, region: String? = nil
  ) {
    self.installationID = installationID
    self.providerID = providerID
    self.displayName = displayName
    self.region = region
  }
}

public struct BridgeDesktopNativeSessionDirectoryState: Codable, Equatable, Sendable {
  public let installations: [BridgeDesktopNativeSessionInstallation]
  public let projectID: String?
  public let installationID: String?
  public let selectedSessionID: String?
  public let sessions: [AgentNativeSessionSummary]
  public let transcript: [AgentNativeSessionMessage]
  public let nextOffset: Int?
  public let transcriptNextOffset: Int?
  public let isOpen: Bool
  public let isLoading: Bool
  public let statusMessage: String?
  public let errorMessage: String?

  public init(
    installations: [BridgeDesktopNativeSessionInstallation] = [],
    projectID: String? = nil,
    installationID: String? = nil,
    selectedSessionID: String? = nil,
    sessions: [AgentNativeSessionSummary] = [],
    transcript: [AgentNativeSessionMessage] = [],
    nextOffset: Int? = nil,
    transcriptNextOffset: Int? = nil,
    isOpen: Bool = false,
    isLoading: Bool = false,
    statusMessage: String? = nil,
    errorMessage: String? = nil
  ) {
    self.installations = installations
    self.projectID = projectID
    self.installationID = installationID
    self.selectedSessionID = selectedSessionID
    self.sessions = sessions
    self.transcript = transcript
    self.nextOffset = nextOffset
    self.transcriptNextOffset = transcriptNextOffset
    self.isOpen = isOpen
    self.isLoading = isLoading
    self.statusMessage = statusMessage
    self.errorMessage = errorMessage
  }
}

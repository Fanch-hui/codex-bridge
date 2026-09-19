import BridgeServiceAppCore
import Foundation

public struct BridgeDesktopAppUpdateState: Codable, Equatable, Sendable {
  public let phase: String
  public let currentVersion: String
  public let availableVersion: String?
  public let notes: String?
  public let progress: Double?
  public let message: String?
  public let isDeferred: Bool

  public init(
    phase: String = "idle",
    currentVersion: String = "",
    availableVersion: String? = nil,
    notes: String? = nil,
    progress: Double? = nil,
    message: String? = nil,
    isDeferred: Bool = false
  ) {
    self.phase = phase
    self.currentVersion = currentVersion
    self.availableVersion = availableVersion
    self.notes = notes
    self.progress = progress
    self.message = message
    self.isDeferred = isDeferred
  }

  public init(status: AppUpdateStatus) {
    self.init(
      phase: status.phase,
      currentVersion: status.currentVersion,
      availableVersion: status.availableVersion,
      notes: status.notes,
      progress: status.progress,
      message: status.message,
      isDeferred: status.isDeferred
    )
  }
}

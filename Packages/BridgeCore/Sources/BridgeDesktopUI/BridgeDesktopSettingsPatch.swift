public struct BridgeDesktopSettingsPatch: Equatable, Sendable {
  public let executionModel: String?
  public let executionEffort: String?
  public let accessMode: String?
  public let fastModeEnabled: Bool?

  public init(
    executionModel: String? = nil,
    executionEffort: String? = nil,
    accessMode: String? = nil,
    fastModeEnabled: Bool? = nil
  ) {
    self.executionModel = executionModel
    self.executionEffort = executionEffort
    self.accessMode = accessMode
    self.fastModeEnabled = fastModeEnabled
  }
}

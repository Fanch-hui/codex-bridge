public struct ServiceApplicationModeStatus: Sendable, Equatable {
  public let mode: ServiceApplicationMode
  public let transition: String?
  public let error: String?

  package init(mode: ServiceApplicationMode, transition: String?, error: String?) {
    self.mode = mode
    self.transition = transition
    self.error = error
  }
}

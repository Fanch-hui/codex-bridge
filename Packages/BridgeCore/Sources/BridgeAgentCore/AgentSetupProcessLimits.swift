public enum AgentSetupProcessLimits {
  public static let maximumRunSeconds: Int64 = 900
  public static let maximumControlSeconds: Int64 = 30
  public static let maximumConnectorRunSeconds = maximumRunSeconds + 2 * maximumControlSeconds
}

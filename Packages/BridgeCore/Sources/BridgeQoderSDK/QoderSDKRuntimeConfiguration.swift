import BridgeAgentCore
import Foundation

public struct QoderSDKRuntimeConfiguration: Equatable, Sendable {
  public let distribution: QoderDistribution
  public let nodeExecutablePath: String?
  public let sdkRoot: String?

  public init(
    distribution: QoderDistribution,
    nodeExecutablePath: String? = nil,
    sdkRoot: String? = nil
  ) {
    self.distribution = distribution
    self.nodeExecutablePath = nodeExecutablePath
    self.sdkRoot = sdkRoot
  }
}

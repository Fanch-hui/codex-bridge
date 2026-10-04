import BridgeAgentCore
import BridgeServiceCore
import Foundation

actor ServiceAgentSetupRuntimeBindings {
  private var qoder: [String: ServiceQoderRuntimeSettings] = [:]

  func stage(_ runtime: ServiceAgentSetupRuntime, distribution: QoderDistribution) {
    qoder[Self.key(runtime.executablePath)] = ServiceQoderRuntimeSettings(
      distribution: distribution, nodeExecutablePath: runtime.nodeExecutablePath,
      sdkRoot: runtime.sdkRoot)
  }

  func staged(for path: String) -> ServiceQoderRuntimeSettings? { qoder[Self.key(path)] }

  func remove(_ path: String) { qoder.removeValue(forKey: Self.key(path)) }

  private static func key(_ path: String) -> String {
    let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    #if os(Windows)
      return canonical.lowercased()
    #else
      return canonical
    #endif
  }
}

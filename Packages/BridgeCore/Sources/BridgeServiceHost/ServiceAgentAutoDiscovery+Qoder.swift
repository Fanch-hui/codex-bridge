import BridgeAgentCore
import BridgeServiceCore
import Foundation

extension ServiceAgentAutoDiscovery {
  static func qoderRequests(
    existingPaths: [String],
    environment: [String: String],
    allowInstallationSearch: Bool = true,
    distribution: QoderDistribution? = nil,
    distributionsByExecutablePath: [String: QoderDistribution] = [:]
  ) throws -> [ServiceAgentRegistrationRequest] {
    let definitions: [(QoderDistribution, [String])] = [
      (.cn, ["qoderclicn", "qodercn"]),
      (.international, ["qodercli", "qoder"]),
    ]
    var result: [ServiceAgentRegistrationRequest] = []
    var seen = Set<String>()
    for (region, names) in definitions where distribution == nil || distribution == region {
      let paths = existingPaths.filter { path in
        (distributionsByExecutablePath[path]
          ?? QoderDistribution.identify(executablePath: path)) == region
      }
      let requests = try commandLineRequests(
        providerID: .qoder,
        names: names,
        displayName: region.installationDisplayName,
        trustProfile: .userTrusted,
        securityProfileID: AgentProfileID(rawValue: "qoder-managed"),
        existingPaths: paths,
        environment: environment,
        allowInstallationSearch: allowInstallationSearch
      )
      for request in requests {
        guard
          (distributionsByExecutablePath[request.executablePath]
            ?? QoderDistribution.identify(executablePath: request.executablePath)) == region
        else {
          continue
        }
        guard
          let executable = try? qoderExecutablePath(request.executablePath, distribution: region),
          seen.insert(AgentPathSemantics.canonicalPath(executable) ?? executable).inserted
        else { continue }
        result.append(
          try ServiceAgentRegistrationRequest(
            providerID: .qoder,
            displayName: region.installationDisplayName,
            executablePath: executable,
            trustProfile: request.trustProfile,
            securityProfileID: request.securityProfileID,
            enableOnSuccess: false
          ))
      }
    }
    return result
  }
}

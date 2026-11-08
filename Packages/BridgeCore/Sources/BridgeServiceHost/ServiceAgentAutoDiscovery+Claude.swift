import BridgeAgentCore
import BridgeServiceCore
import Foundation

extension ServiceAgentAutoDiscovery {
  static func claudeCodeRequests(
    existingPaths: [String], environment: [String: String],
    allowInstallationSearch: Bool = true
  ) throws -> [ServiceAgentRegistrationRequest] {
    let requests = try commandLineRequests(
      providerID: .claudeCode, names: ["claude"], displayName: "Claude Code",
      trustProfile: .userTrusted, securityProfileID: AgentProfileID(rawValue: "claude-managed"),
      existingPaths: existingPaths, environment: environment,
      allowInstallationSearch: allowInstallationSearch)
    #if os(Windows)
      let installer = ServiceAgentSetupInstaller()
      var seen = Set<String>()
      return try requests.compactMap { request in
        guard
          let normalized = installer.normalizeExisting(
            request.executablePath, providerID: .claudeCode, distribution: nil),
          let executable = canonicalRegularFile(normalized), !isWindowsGUIExecutable(executable),
          seen.insert(pathKey(executable)).inserted
        else { return nil }
        return try ServiceAgentRegistrationRequest(
          providerID: .claudeCode, displayName: request.displayName,
          executablePath: executable, trustProfile: request.trustProfile,
          securityProfileID: request.securityProfileID, enableOnSuccess: false)
      }
    #else
      return requests
    #endif
  }
}

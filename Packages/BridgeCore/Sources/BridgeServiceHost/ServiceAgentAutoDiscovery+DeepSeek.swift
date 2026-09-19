import BridgeAgentCore
import BridgeDeepSeekHarnessACP
import BridgeServiceApplication
import BridgeServiceCore
import Foundation

extension ServiceAgentAutoDiscovery {
  static func deepSeekRequests(
    dataPaths: ServiceDataPaths,
    existingInstallations: [ServiceAgentInstallationRecord],
    preferGeneratedConfiguration: Bool,
    environment: [String: String],
    allowGeneratedConfiguration: Bool = true
  ) throws -> [ServiceAgentRegistrationRequest] {
    var executables =
      ([managedDeepSeekExecutable(dataPaths: dataPaths)]
      + deepSeekExecutableCandidates(
        existingInstallations: existingInstallations,
        environment: environment,
        includeSourceSearch: false
      )).compactMap(canonicalRegularFile)
    #if os(Windows)
      executables = executables.filter { !isWindowsGUIExecutable($0) }
    #endif
    guard !executables.isEmpty else { return [] }

    var configurations: [String]
    if preferGeneratedConfiguration {
      configurations =
        try makeGeneratedDeepSeekConfiguration(at: dataPaths.agentStateURL)
        .map { [$0] } ?? []
    } else {
      configurations = deepSeekConfigurationCandidates(
        existingInstallations: existingInstallations,
        environment: environment
      ).compactMap(canonicalRegularFile)
    }
    if configurations.isEmpty, allowGeneratedConfiguration,
      let generated = try makeGeneratedDeepSeekConfiguration(at: dataPaths.agentStateURL)
    {
      configurations = [generated]
    }
    var requests: [ServiceAgentRegistrationRequest] = []
    var validationError: (any Error)?
    var seen = Set<String>()
    for executable in executables {
      for configuration in configurations {
        let key = "\(pathKey(executable))\n\(pathKey(configuration))"
        guard seen.insert(key).inserted else { continue }
        let artifacts: [AgentInstallationArtifactRole: String]
        do {
          artifacts = try DeepSeekHarnessACPProfile.resolveArtifacts(
            executablePath: executable,
            configurationPath: configuration,
            sourceEnvironment: environment
          )
        } catch {
          validationError = error
          continue
        }
        requests.append(
          try ServiceAgentRegistrationRequest(
            providerID: .deepSeekHarness,
            displayName: "DeepSeek Harness",
            executablePath: executable,
            trustProfile: .userTrusted,
            securityProfileID: ServiceAgentProviderPolicyRegistry.controlledReadOnlyProfileID,
            enableOnSuccess: false,
            configurationPath: configuration,
            artifacts: artifacts.filter { $0.key != .launchConfiguration }.map { role, path in
              try ServiceAgentInstallationArtifactRequest(role: role, path: path)
            }
          )
        )
      }
    }
    if requests.isEmpty, let validationError { throw validationError }
    return requests
  }

  static func deepSeekExecutableCandidates(
    existingInstallations: [ServiceAgentInstallationRecord],
    environment: [String: String],
    includeSourceSearch: Bool = true
  ) -> [String] {
    var knownCandidates = existingInstallations.map(\.executablePath)
    for key in [
      "CODEX_BRIDGE_DEEPSEEK_HARNESS_EXECUTABLE",
      "DEEPSEEK_HARNESS_EXECUTABLE",
    ] {
      if let value = environmentValue(key, environment: environment) {
        knownCandidates.append(value)
      }
    }
    knownCandidates.append(
      contentsOf: deepSeekSourceRoots(environment: environment).flatMap {
        [
          pathJoin($0, "apps", "cli", "lib", "bin.js"),
          pathJoin($0, "packages", "examples", "acp-demo", "lib", "bin.js"),
        ]
      }
    )
    knownCandidates.append(contentsOf: deepSeekLauncherCandidates(environment: environment))

    // PATH, package-manager launchers and an explicitly supplied root are cheap
    // and authoritative. Only when they produce no file do we inspect the
    // bounded set of local development directories.
    let known = uniquePaths(knownCandidates)
    if known.contains(where: { canonicalRegularFile($0) != nil }) {
      return known
    }
    guard includeSourceSearch else { return known }
    let discoveredRoots = ServiceAgentDeepSeekSourceSearch.discover(environment: environment)
    let discoveredEntries = discoveredRoots.map {
      pathJoin($0, "apps", "cli", "lib", "bin.js")
    }
    return uniquePaths(known + discoveredEntries)
  }

  static func deepSeekConfigurationCandidates(
    existingInstallations: [ServiceAgentInstallationRecord],
    environment: [String: String]
  ) -> [String] {
    var candidates = existingInstallations.compactMap { installation in
      installation.artifacts.first(where: { $0.role == .launchConfiguration })?.canonicalPath
    }
    for key in [
      "CODEX_BRIDGE_DEEPSEEK_HARNESS_CONFIGURATION",
      "DEEPSEEK_HARNESS_CONFIGURATION",
    ] {
      if let value = environmentValue(key, environment: environment) { candidates.append(value) }
    }
    if let home = homeDirectory(environment: environment) {
      candidates.append(contentsOf: [
        pathJoin(home, ".codex-bridge", "deepseek-harness", "cordis.yml"),
        pathJoin(home, ".config", "codex-bridge", "deepseek-harness", "cordis.yml"),
        pathJoin(home, ".deepseek-harness", "cordis.yml"),
      ])
      #if os(Windows)
        if let local = environmentValue("LOCALAPPDATA", environment: environment) {
          candidates.append(pathJoin(local, "CodexBridge", "DeepSeekHarness", "cordis.yml"))
        }
      #else
        candidates.append(
          pathJoin(
            home,
            "Library",
            "Application Support",
            "CodexBridge",
            "DeepSeekHarness",
            "cordis.yml"
          )
        )
      #endif
    }
    return uniquePaths(candidates)
  }

  private static func deepSeekSourceRoots(
    environment: [String: String]
  ) -> [String] {
    var roots: [String] = []
    for key in [
      "CODEX_BRIDGE_DEEPSEEK_HARNESS_ROOT",
      "DEEPSEEK_HARNESS_ROOT",
    ] {
      if let value = environmentValue(key, environment: environment) { roots.append(value) }
    }
    #if os(Windows)
      if let programFiles = environmentValue("ProgramFiles", environment: environment) {
        roots.append(pathJoin(programFiles, "deepseek-harness"))
      }
    #endif
    if let home = homeDirectory(environment: environment) {
      roots.append(
        contentsOf: [
          "deepseek-harness", "deepseek-harness-acp", "Projects/deepseek-harness",
          "Development/deepseek-harness", "src/deepseek-harness", "Code/deepseek-harness",
          "Documents/deepseek-harness",
        ].map { pathJoin(home, $0) })
    }
    return uniquePaths(roots)
  }

  private static func makeGeneratedDeepSeekConfiguration(at root: URL) throws -> String? {
    let directory = root.appendingPathComponent("DeepSeekHarnessAuto", isDirectory: true)
    let configuration = directory.appendingPathComponent("cordis.yml", isDirectory: false)
    if FileManager.default.fileExists(atPath: configuration.path) {
      return canonicalRegularFile(configuration.path)
    }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    let template = try DeepSeekHarnessACPProfile.bundledConfigurationTemplate()
    try template.write(to: configuration, options: .atomic)
    #if !os(Windows)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: configuration.path
      )
    #endif
    return canonicalRegularFile(configuration.path)
  }
}

import BridgeAgentCore
import Foundation

extension DeepSeekHarnessACPLaunchBuilder {
  func makeEnvironment(
    nodeInterpreter: String,
    projectRoot: String,
    runDirectory: String,
    persistentStateDirectory: String?,
    mutationIntent: AgentMutationIntent,
    sourceEnvironment: [String: String]
  ) throws -> [String: String] {
    let home = try AgentProviderEnvironment.homeDirectory(source: sourceEnvironment)
    let xdgConfig = try DeepSeekHarnessACPPathSupport.append("xdg-config", to: runDirectory)
    let xdgCache = try DeepSeekHarnessACPPathSupport.append("xdg-cache", to: runDirectory)
    let xdgData = try DeepSeekHarnessACPPathSupport.append("xdg-data", to: runDirectory)
    let xdgState = try DeepSeekHarnessACPPathSupport.append("xdg-state", to: runDirectory)
    let temporary = try DeepSeekHarnessACPPathSupport.append("tmp", to: runDirectory)
    let dshHome = try DeepSeekHarnessACPPathSupport.append("dsh-home", to: runDirectory)
    let snapshots: String
    if let persistentStateDirectory {
      snapshots = try DeepSeekHarnessACPPathSupport.preparePrivateDirectory(
        persistentStateDirectory,
        field: "persistentStateDirectory"
      )
    } else {
      snapshots = try DeepSeekHarnessACPPathSupport.append("snapshots", to: runDirectory)
    }
    for path in [xdgConfig, xdgCache, xdgData, xdgState, temporary, dshHome, snapshots] {
      try DeepSeekHarnessACPPathSupport.createPrivateDirectory(path)
    }

    var environment: [String: String] = [
      "HOME": home,
      "PATH": AgentProviderEnvironment.executableSearchPath(
        executablePath: nodeInterpreter,
        source: sourceEnvironment
      ),
      "TMPDIR": temporary,
      "XDG_CONFIG_HOME": xdgConfig,
      "XDG_CACHE_HOME": xdgCache,
      "XDG_DATA_HOME": xdgData,
      "XDG_STATE_HOME": xdgState,
      "DSH_HOME": dshHome,
      "DSH_SNAPSHOT_SESSIONS_ROOT": snapshots,
      "DSH_WORKSPACE_ROOT": projectRoot,
      "DSH_PERMISSION_MODE": Self.permissionMode(for: mutationIntent),
    ]
    for key in ["USER", "LOGNAME", "LANG", "LC_ALL", "SHELL"] {
      if let value = sourceEnvironment[key],
        !value.isEmpty,
        !value.contains("\0"),
        value.rangeOfCharacter(from: .controlCharacters) == nil
      {
        environment[key] = value
      }
    }
    for key in [
      "DEEPSEEK_API_KEY", "DEEPSEEK_BASE_URL", "DEEPSEEK_SEARCH_BASE_URL", "BRIDGE_DSH_PROTOCOL",
      "BRIDGE_DSH_CATALOG_BASE_URL",
    ] {
      if let value = sourceEnvironment[key], !value.isEmpty, !value.contains("\0"),
        value.rangeOfCharacter(from: .controlCharacters) == nil
      {
        environment[key] = value
      }
    }
    DeepSeekHarnessACPProxyEnvironment.apply(to: &environment, from: sourceEnvironment)
    #if os(Windows)
      environment["USERPROFILE"] = home
      environment["TEMP"] = temporary
      environment["TMP"] = temporary
      AgentProviderEnvironment.applyWindowsSystemEnvironment(
        to: &environment, from: sourceEnvironment)
    #endif
    return environment
  }

}

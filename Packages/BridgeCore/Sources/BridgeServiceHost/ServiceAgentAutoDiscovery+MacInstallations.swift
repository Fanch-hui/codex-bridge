import Foundation

extension ServiceAgentAutoDiscovery {
  /// Returns deterministic user installation directories that are commonly
  /// hidden from a LaunchAgent's PATH. This only reads directory metadata; it
  /// never invokes a shell or reads shell profiles.
  static func macOSAgentSearchDirectories(
    environment: [String: String]
  ) -> [String] {
    #if os(macOS)
      guard let home = homeDirectory(environment: environment) else { return [] }

      var directories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        pathJoin(home, "bin"),
        pathJoin(home, ".local", "bin"),
        pathJoin(home, ".cargo", "bin"),
        pathJoin(home, ".bun", "bin"),
        pathJoin(home, ".volta", "bin"),
        pathJoin(home, ".asdf", "shims"),
        pathJoin(home, ".mise", "shims"),
        pathJoin(home, ".nodenv", "shims"),
        pathJoin(home, ".yarn", "bin"),
        pathJoin(home, ".config", "yarn", "global", "node_modules", ".bin"),
        pathJoin(home, "Library", "pnpm"),
        pathJoin(home, ".local", "share", "pnpm"),
        pathJoin(home, ".npm-global", "bin"),
        pathJoin(home, ".config", "npm", "bin"),
        pathJoin(home, "Library", "npm", "bin"),
        pathJoin(home, ".opencode", "bin"),
        pathJoin(home, ".antigravity", "bin"),
      ]

      for applications in ["/Applications", pathJoin(home, "Applications")] {
        for bundle in ["OpenCode.app", "opencode.app"] {
          directories.append(pathJoin(applications, bundle, "Contents", "MacOS"))
          directories.append(pathJoin(applications, bundle, "Contents", "Resources"))
        }
      }
      appendEnvironmentManagerDirectories(environment: environment, to: &directories)
      appendNVMDirectories(home: home, environment: environment, to: &directories)
      appendFNMDirectories(home: home, environment: environment, to: &directories)
      return uniquePaths(directories)
    #else
      _ = environment
      return []
    #endif
  }

  private static func appendEnvironmentManagerDirectories(
    environment: [String: String],
    to directories: inout [String]
  ) {
    for key in ["NPM_CONFIG_PREFIX", "npm_config_prefix"] {
      if let prefix = environmentValue(key, environment: environment) {
        directories += [prefix, pathJoin(prefix, "bin")]
      }
    }
    if let pnpmHome = environmentValue("PNPM_HOME", environment: environment) {
      directories.append(pnpmHome)
    }
    if let yarnGlobalFolder = environmentValue("YARN_GLOBAL_FOLDER", environment: environment) {
      directories += [
        yarnGlobalFolder,
        pathJoin(yarnGlobalFolder, "bin"),
        pathJoin(yarnGlobalFolder, "node_modules", ".bin"),
      ]
    }
    if let corepackHome = environmentValue("COREPACK_HOME", environment: environment) {
      directories += [corepackHome, pathJoin(corepackHome, "shims")]
    }
    if let bunInstall = environmentValue("BUN_INSTALL", environment: environment) {
      directories += [bunInstall, pathJoin(bunInstall, "bin")]
    }
    if let voltaHome = environmentValue("VOLTA_HOME", environment: environment) {
      directories.append(pathJoin(voltaHome, "bin"))
    }
    if let asdfData = environmentValue("ASDF_DATA_DIR", environment: environment) {
      directories.append(pathJoin(asdfData, "shims"))
    }
    if let miseData = environmentValue("MISE_DATA_DIR", environment: environment) {
      directories.append(pathJoin(miseData, "shims"))
    }
  }

  private static func appendNVMDirectories(
    home: String,
    environment: [String: String],
    to directories: inout [String]
  ) {
    let root =
      environmentValue("NVM_DIR", environment: environment)
      ?? pathJoin(home, ".nvm")
    directories += [
      pathJoin(root, "current", "bin"),
      pathJoin(root, "versions", "node", "current", "bin"),
    ]
    let versions = pathJoin(root, "versions", "node")
    directories.append(contentsOf: immediateDirectories(at: versions).map { pathJoin($0, "bin") })
  }

  private static func appendFNMDirectories(
    home: String,
    environment: [String: String],
    to directories: inout [String]
  ) {
    let root =
      environmentValue("FNM_DIR", environment: environment)
      ?? pathJoin(home, "Library", "Application Support", "fnm")
    directories += [
      pathJoin(root, "aliases", "default", "bin"),
      pathJoin(root, "node-versions", "current", "installation", "bin"),
    ]
    let versions = pathJoin(root, "node-versions")
    for version in immediateDirectories(at: versions) {
      directories.append(pathJoin(version, "installation", "bin"))
    }
  }

  private static func immediateDirectories(at path: String) -> [String] {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: []
      )
    else { return [] }
    return entries.compactMap { entry in
      guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey]),
        values.isDirectory == true
      else {
        return nil
      }
      return pathJoin(path, entry.lastPathComponent)
    }
  }
}

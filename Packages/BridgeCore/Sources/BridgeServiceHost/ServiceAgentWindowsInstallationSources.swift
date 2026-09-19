#if os(Windows)
  import BridgeAgentCore
  import Foundation
  import WinSDK

  /// Windows installation locations that are not reliably present in the
  /// service process environment. The helper only reads well-known registry
  /// metadata and never walks an installation tree.
  enum ServiceAgentWindowsInstallationSources {
    static func searchDirectories(
      names: [String],
      environment: [String: String]
    ) -> [String] {
      let baseline = uniquePaths(baselineDirectories(names: names, environment: environment))
      guard !hasUsableCandidate(names: names, directories: baseline) else {
        return baseline
      }

      let appPaths = appPathDirectories(names: names)
      let withAppPaths = uniquePaths(baseline + appPaths)
      guard !hasUsableCandidate(names: names, directories: withAppPaths) else {
        return withAppPaths
      }

      return uniquePaths(
        withAppPaths + cliSubdirectories(uninstallDirectories(names: names))
      )
    }

    private static func cliSubdirectories(_ roots: [String]) -> [String] {
      roots.flatMap { root in
        [
          root, pathJoin(root, "bin"), pathJoin(root, "cli"),
          pathJoin(root, "cli", "bin"), pathJoin(root, "resources"),
          pathJoin(root, "resources", "app", "bin"),
        ]
      }
    }

    private static func baselineDirectories(
      names: [String],
      environment: [String: String]
    ) -> [String] {
      var directories =
        environmentValue("PATH", environment: environment)
        .map { AgentPathSemantics.splitPathList($0, style: .windows) } ?? []
      guard
        let home = environmentValue("USERPROFILE", environment: environment)
          ?? environmentValue("HOME", environment: environment)
      else { return directories }

      directories += [
        pathJoin(home, ".opencode", "bin"),
        pathJoin(home, ".antigravity", "bin"),
        pathJoin(home, ".local", "bin"),
        pathJoin(home, ".bun", "bin"),
        pathJoin(home, ".cargo", "bin"),
        pathJoin(home, "scoop", "shims"),
      ]
      if let appData = environmentValue("APPDATA", environment: environment) {
        directories += [
          pathJoin(appData, "npm"),
          pathJoin(appData, "pnpm"),
          pathJoin(appData, "Yarn", "bin"),
        ]
      }
      if let local = environmentValue("LOCALAPPDATA", environment: environment) {
        directories += [
          pathJoin(local, "npm"),
          pathJoin(local, "pnpm"),
          pathJoin(local, "Programs", "nodejs"),
          pathJoin(local, "Programs", "Yarn", "bin"),
          pathJoin(local, "Programs", "Git", "cmd"),
          pathJoin(local, "Microsoft", "WinGet", "Links"),
          pathJoin(local, "Microsoft", "WindowsApps"),
          pathJoin(local, "Volta", "bin"),
        ]
      }

      for key in [
        "PNPM_HOME", "NPM_CONFIG_PREFIX", "YARN_GLOBAL_FOLDER", "COREPACK_HOME",
        "ChocolateyInstall",
      ] {
        guard let root = environmentValue(key, environment: environment) else { continue }
        directories += [
          root, pathJoin(root, "bin"), pathJoin(root, "global", "node_modules", ".bin"),
        ]
      }

      let programRoots = [
        environmentValue("ProgramW6432", environment: environment),
        environmentValue("ProgramFiles", environment: environment),
        environmentValue("ProgramFiles(x86)", environment: environment),
      ].compactMap { $0 }
      if let programData = environmentValue("ProgramData", environment: environment) {
        directories += [
          pathJoin(programData, "chocolatey", "bin"), pathJoin(programData, "scoop", "shims"),
        ]
      }
      for root in programRoots {
        directories += [
          pathJoin(root, "nodejs"), pathJoin(root, "Git", "cmd"),
          pathJoin(root, "PowerShell", "7"),
        ]
        directories += installationDirectories(
          roots: [pathJoin(root)], names: names
        )
      }
      if let local = environmentValue("LOCALAPPDATA", environment: environment) {
        directories += installationDirectories(
          roots: [pathJoin(local, "Programs"), pathJoin(local)], names: names
        )
      }
      if let appData = environmentValue("APPDATA", environment: environment) {
        directories += installationDirectories(roots: [pathJoin(appData)], names: names)
      }
      return directories
    }

    private static func installationDirectories(roots: [String], names: [String]) -> [String] {
      let variants = uniqueStrings(names + ["OpenCode", "Antigravity", "AGY"])
      return roots.flatMap { root in
        variants.flatMap { name in
          let installRoot = pathJoin(root, name)
          return [
            installRoot,
            pathJoin(installRoot, "bin"),
            pathJoin(installRoot, "cli"),
            pathJoin(installRoot, "cli", "bin"),
            pathJoin(installRoot, "resources"),
            pathJoin(installRoot, "resources", "app"),
            pathJoin(installRoot, "resources", "app", "bin"),
            pathJoin(installRoot, "resources", "app", "out"),
          ]
        }
      }
    }

    private static func hasUsableCandidate(names: [String], directories: [String]) -> Bool {
      let suffixes = [".exe", ".com", ".cmd", ".bat"]
      for directory in directories {
        for name in names {
          for suffix in suffixes {
            let path = pathJoin(directory, name + suffix)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if suffix == ".exe" && ServiceAgentAutoDiscovery.isWindowsGUIExecutable(path) {
              continue
            }
            return true
          }
        }
      }
      return false
    }

    private static func environmentValue(_ key: String, environment: [String: String]) -> String? {
      guard
        let value = environment.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }
        )?.value,
        !value.isEmpty,
        value.rangeOfCharacter(from: .controlCharacters) == nil,
        !value.contains("\0")
      else { return nil }
      return value
    }

    private static func pathJoin(_ first: String, _ components: String...) -> String {
      var value = first
      for component in components {
        if !value.hasSuffix("\\") { value.append("\\") }
        value.append(component.replacingOccurrences(of: "/", with: "\\"))
      }
      return value
    }

    private static func uniquePaths(_ values: [String]) -> [String] {
      var seen = Set<String>()
      return values.compactMap { value in
        guard let canonical = AgentPathSemantics.canonicalPath(value, style: .windows),
          AgentPathSemantics.isAbsolute(canonical, style: .windows),
          seen.insert(canonical.lowercased()).inserted
        else { return nil }
        return canonical
      }
    }

    static func uniqueStrings(_ values: [String]) -> [String] {
      var seen = Set<String>()
      return values.filter { seen.insert($0.lowercased()).inserted }
    }
  }
#endif

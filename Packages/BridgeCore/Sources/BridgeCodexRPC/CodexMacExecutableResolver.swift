#if !os(Windows)
  import BridgeAgentCore
  import Foundation

  enum CodexMacExecutableResolver {
    static func resolve(
      environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
      candidates(environment: environment).first(where: isExecutable).map(
        URL.init(fileURLWithPath:))
    }

    /// Resolves a user-configured path, which must point at an executable file.
    static func resolve(configuredPath: String) -> URL? {
      guard let normalized = AgentPathSemantics.canonicalPath(configuredPath),
        AgentPathSemantics.isAbsolute(normalized), !normalized.contains("\0"),
        normalized.utf8.count <= 16 * 1_024
      else { return nil }
      var isDirectory = ObjCBool(false)
      guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory),
        !isDirectory.boolValue,
        FileManager.default.isExecutableFile(atPath: normalized)
      else { return nil }
      return URL(fileURLWithPath: normalized)
    }

    static func candidates(environment: [String: String]) -> [String] {
      let home = homeDirectory(environment: environment)
      var values: [String] = []
      if let configured = environmentValue("CODEX_BRIDGE_CODEX_EXECUTABLE", in: environment) {
        values.append(configured)
      }

      values += bundleCandidates(home: home)
      values += packageManagerCandidates(home: home, environment: environment)
      if let path = environmentValue("PATH", in: environment) {
        values += AgentPathSemantics.splitPathList(path).map { join($0, "codex") }
      }
      if let home {
        values.append(
          join(
            home,
            "Library",
            "Application Support",
            "codex-plusplus",
            "backup",
            "Codex.app",
            "Contents",
            "Resources",
            "codex"
          )
        )
      }
      return uniquePaths(values)
    }

    private static func bundleCandidates(home: String?) -> [String] {
      var values = [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        "/Applications/ChatGPT.app/Contents/Resources/bin/codex",
        "/Applications/Codex.app/Contents/Resources/bin/codex",
      ]
      if let home {
        values += [
          join(home, "Applications", "ChatGPT.app", "Contents", "Resources", "codex"),
          join(home, "Applications", "Codex.app", "Contents", "Resources", "codex"),
          join(home, "Applications", "ChatGPT.app", "Contents", "Resources", "bin", "codex"),
          join(home, "Applications", "Codex.app", "Contents", "Resources", "bin", "codex"),
        ]
      }
      return values
    }

    private static func packageManagerCandidates(
      home: String?,
      environment: [String: String]
    ) -> [String] {
      guard let home else { return [] }
      var directories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/sw/bin",
        join(home, "bin"),
        join(home, ".local", "bin"),
        join(home, ".cargo", "bin"),
        join(home, ".bun", "bin"),
        join(home, ".volta", "bin"),
        join(home, ".asdf", "shims"),
        join(home, ".mise", "shims"),
        join(home, ".nodenv", "shims"),
        join(home, "Library", "pnpm"),
        join(home, ".local", "share", "pnpm"),
        join(home, "Library", "Application Support", "pnpm"),
        join(home, ".npm-global", "bin"),
        join(home, ".npm-packages", "bin"),
        join(home, "Library", "npm", "bin"),
      ]

      appendEnvironmentDirectories(environment: environment, to: &directories)
      appendNVMDirectories(home: home, environment: environment, to: &directories)
      appendFNMDirectories(home: home, environment: environment, to: &directories)
      return directories.map { join($0, "codex") }
    }

    private static func appendEnvironmentDirectories(
      environment: [String: String],
      to directories: inout [String]
    ) {
      for key in ["NPM_CONFIG_PREFIX", "npm_config_prefix"] {
        if let prefix = environmentValue(key, in: environment) {
          directories += [prefix, join(prefix, "bin")]
        }
      }
      if let value = environmentValue("PNPM_HOME", in: environment) {
        directories.append(value)
      }
      if let value = environmentValue("BUN_INSTALL", in: environment) {
        directories += [value, join(value, "bin")]
      }
      if let value = environmentValue("VOLTA_HOME", in: environment) {
        directories.append(join(value, "bin"))
      }
      if let value = environmentValue("ASDF_DATA_DIR", in: environment) {
        directories.append(join(value, "shims"))
      }
      if let value = environmentValue("MISE_DATA_DIR", in: environment) {
        directories.append(join(value, "shims"))
      }
      if let value = environmentValue("COREPACK_HOME", in: environment) {
        directories += [value, join(value, "shims")]
      }
      if let value = environmentValue("YARN_GLOBAL_FOLDER", in: environment) {
        directories += [
          value,
          join(value, "bin"),
          join(value, "node_modules", ".bin"),
        ]
      }
    }

    private static func appendNVMDirectories(
      home: String,
      environment: [String: String],
      to directories: inout [String]
    ) {
      let root = environmentValue("NVM_DIR", in: environment) ?? join(home, ".nvm")
      directories += [
        join(root, "current", "bin"),
        join(root, "versions", "node", "current", "bin"),
      ]
      let versions = join(root, "versions", "node")
      directories.append(contentsOf: immediateDirectories(at: versions).map { join($0, "bin") })
    }

    private static func appendFNMDirectories(
      home: String,
      environment: [String: String],
      to directories: inout [String]
    ) {
      let root =
        environmentValue("FNM_DIR", in: environment)
        ?? join(home, "Library", "Application Support", "fnm")
      directories += [
        join(root, "aliases", "default", "bin"),
        join(root, "node-versions", "current", "installation", "bin"),
      ]
      let versions = join(root, "node-versions")
      for version in immediateDirectories(at: versions) {
        directories.append(join(version, "installation", "bin"))
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
        return join(path, entry.lastPathComponent)
      }
    }

    private static func homeDirectory(environment: [String: String]) -> String? {
      let value =
        environmentValue("HOME", in: environment)
        ?? FileManager.default.homeDirectoryForCurrentUser.path
      guard AgentPathSemantics.isAbsolute(value), !value.contains("\0") else { return nil }
      return AgentPathSemantics.canonicalPath(value)
    }

    private static func environmentValue(_ key: String, in environment: [String: String]) -> String?
    {
      guard let value = environment[key], !value.isEmpty,
        !value.contains("\0"), value.rangeOfCharacter(from: .controlCharacters) == nil
      else { return nil }
      return value
    }

    private static func isExecutable(_ path: String) -> Bool {
      guard let normalized = AgentPathSemantics.canonicalPath(path),
        AgentPathSemantics.isAbsolute(normalized)
      else { return false }
      return FileManager.default.isExecutableFile(atPath: normalized)
    }

    private static func join(_ first: String, _ components: String...) -> String {
      var value = first
      for component in components {
        if !value.hasSuffix("/") { value.append("/") }
        value.append(component.replacingOccurrences(of: "\\", with: "/"))
      }
      return value
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
      var seen = Set<String>()
      return paths.compactMap { path in
        guard let normalized = AgentPathSemantics.canonicalPath(path),
          AgentPathSemantics.isAbsolute(normalized), seen.insert(normalized).inserted
        else { return nil }
        return normalized
      }
    }
  }
#endif

#if os(Linux)
  import Foundation

  public enum LinuxAgentInstallationDirectories {
    public static func search(environment: [String: String]) -> [String] {
      let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
      let data = environment["XDG_DATA_HOME"] ?? join(home, ".local/share")
      var directories = [
        "/usr/local/bin", "/usr/bin", "/bin", "/snap/bin",
        join(home, "bin"), join(home, ".local/bin"), join(home, ".cargo/bin"),
        join(home, ".bun/bin"), join(home, ".volta/bin"), join(home, ".asdf/shims"),
        join(home, ".mise/shims"), join(home, ".nodenv/shims"), join(home, ".yarn/bin"),
        join(home, ".config/yarn/global/node_modules/.bin"), join(data, "pnpm"),
        join(home, ".npm-global/bin"), join(home, ".npm-packages/bin"),
        join(home, ".config/npm/bin"), join(home, ".opencode/bin"),
        join(home, ".antigravity/bin"), join(home, ".qoder/bin"), join(home, ".qoder-cn/bin"),
      ]
      for key in ["NPM_CONFIG_PREFIX", "npm_config_prefix", "BUN_INSTALL"] {
        if let prefix = environment[key] { directories += [prefix, join(prefix, "bin")] }
      }
      for key in ["PNPM_HOME", "COREPACK_HOME"] {
        if let path = environment[key] { directories += [path, join(path, "shims")] }
      }
      for key in ["VOLTA_HOME", "YARN_GLOBAL_FOLDER"] {
        if let path = environment[key] { directories += [join(path, "bin")] }
      }
      for key in ["ASDF_DATA_DIR", "MISE_DATA_DIR"] {
        if let path = environment[key] { directories += [join(path, "shims")] }
      }
      let nvm = environment["NVM_DIR"] ?? join(home, ".nvm")
      directories += [join(nvm, "current/bin"), join(nvm, "versions/node/current/bin")]
      directories += children(join(nvm, "versions/node")).map { join($0, "bin") }
      let fnm = environment["FNM_DIR"] ?? join(data, "fnm")
      directories += [join(fnm, "aliases/default/bin")]
      directories += children(join(fnm, "node-versions")).map { join($0, "installation/bin") }
      var seen = Set<String>()
      return directories.compactMap { path in
        guard !path.contains("\0"), path.rangeOfCharacter(from: .controlCharacters) == nil,
          let canonical = AgentPathSemantics.canonicalPath(path),
          AgentPathSemantics.isAbsolute(canonical), seen.insert(canonical).inserted
        else { return nil }
        return canonical
      }
    }

    private static func children(_ path: String) -> [String] {
      guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
        return []
      }
      return entries.sorted().compactMap { name in
        let child = join(path, name)
        var directory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: child, isDirectory: &directory)
          && directory.boolValue ? child : nil
      }
    }

    private static func join(_ parent: String, _ child: String) -> String {
      URL(fileURLWithPath: parent, isDirectory: true).appendingPathComponent(child).path
    }
  }
#endif

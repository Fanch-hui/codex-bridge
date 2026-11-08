import Foundation

#if os(macOS)
  import Darwin
#endif

public enum CodexIsolatedLaunchError: Error, Equatable, Sendable {
  case unavailable
  case invalidDirectory
  case overlappingDirectories
  case invalidSourceConfiguration
}

/// Runs an app-server and its local descendants within a private write boundary.
public enum CodexIsolatedLaunch {
  /// Cached after a probe verifies writes, child-process inheritance and symlink handling.
  public static var isAvailable: Bool { availability }

  /// Codex currently accesses project files through command processes.
  public static var supportsFileOnlyExecution: Bool { false }

  public static func prepare(
    configuration: AppServerConfiguration,
    workspaceRoot: URL,
    runtimeDirectory: URL
  ) throws -> AppServerConfiguration {
    #if os(macOS)
      guard isAvailable else { throw CodexIsolatedLaunchError.unavailable }
      guard configuration.launchFailureReason == nil else {
        throw CodexIsolatedLaunchError.invalidSourceConfiguration
      }
      let workspace = try existingDirectory(workspaceRoot)
      let runtime = try existingDirectory(runtimeDirectory)
      guard !overlaps(workspace.path, runtime.path) else {
        throw CodexIsolatedLaunchError.overlappingDirectories
      }

      var environment = configuration.environment ?? ProcessInfo.processInfo.environment
      let sourceHome = sourceCodexHome(environment)
      if let sourceHome,
        overlaps(sourceHome.path, workspace.path) || overlaps(sourceHome.path, runtime.path)
      {
        throw CodexIsolatedLaunchError.overlappingDirectories
      }
      let home = try privateDirectory("home", in: runtime)
      let temporary = try privateDirectory("tmp", in: runtime)
      let cache = try privateDirectory("cache", in: runtime)
      let config = try privateDirectory("config", in: runtime)
      let data = try privateDirectory("data", in: runtime)
      if let sourceHome {
        try linkReadOnlySources(from: sourceHome, to: home, protectedRoots: [workspace, runtime])
      }
      try prepareConfigSnapshot(from: sourceHome, in: home, protectedRoots: [workspace, runtime])
      environment["CODEX_HOME"] = home.path
      environment["TMPDIR"] = temporary.path + "/"
      environment["TMP"] = temporary.path
      environment["TEMP"] = temporary.path
      environment["XDG_CACHE_HOME"] = cache.path
      environment["XDG_CONFIG_HOME"] = config.path
      environment["XDG_DATA_HOME"] = data.path

      return AppServerConfiguration(
        executableURL: sandboxExecutable,
        arguments: [
          "-p", try profile(workspace: workspace, runtime: runtime),
          configuration.executableURL.path,
        ]
          + configuration.arguments,
        currentDirectoryURL: workspace,
        environment: environment,
        maximumProtocolLineBytes: configuration.maximumProtocolLineBytes,
        stderrBufferBytes: configuration.stderrBufferBytes
      )
    #else
      throw CodexIsolatedLaunchError.unavailable
    #endif
  }

  #if os(macOS)
    private static let sandboxExecutable = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    private static let availability = probe()

    private static func existingDirectory(_ url: URL) throws -> URL {
      guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
        throw CodexIsolatedLaunchError.invalidDirectory
      }
      let values: URLResourceValues
      do {
        values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      } catch {
        throw CodexIsolatedLaunchError.invalidDirectory
      }
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw CodexIsolatedLaunchError.invalidDirectory
      }
      let resolved = try physicalURL(url)
      _ = try quotedPath(resolved.path)
      return resolved
    }

    private static func physicalURL(_ url: URL) throws -> URL {
      guard let buffer = url.path.withCString({ realpath($0, nil) }) else {
        throw CodexIsolatedLaunchError.invalidDirectory
      }
      defer { free(buffer) }
      return URL(fileURLWithPath: String(cString: buffer))
    }

    private static func privateDirectory(_ name: String, in root: URL) throws -> URL {
      let child = root.appendingPathComponent(name, isDirectory: true)
      if !FileManager.default.fileExists(atPath: child.path) {
        do {
          try FileManager.default.createDirectory(
            at: child, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        } catch {
          guard (try? existingDirectory(child)) != nil else {
            throw CodexIsolatedLaunchError.invalidDirectory
          }
        }
      }
      let resolved = try existingDirectory(child)
      guard contains(root.path, resolved.path), resolved.path != root.path else {
        throw CodexIsolatedLaunchError.invalidDirectory
      }
      return resolved
    }

    private static func sourceCodexHome(_ environment: [String: String]) -> URL? {
      if let path = environment["CODEX_HOME"], !path.isEmpty {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return (try? physicalURL(url)) ?? url.standardizedFileURL
      }
      guard let home = environment["HOME"], home.hasPrefix("/"), !home.contains("\0") else {
        return nil
      }
      let url = URL(fileURLWithPath: home, isDirectory: true)
        .appendingPathComponent(".codex", isDirectory: true)
      return (try? physicalURL(url)) ?? url.standardizedFileURL
    }

    private static func linkReadOnlySources(from source: URL, to home: URL, protectedRoots: [URL])
      throws
    {
      let manager = FileManager.default
      for name in ["auth.json", "AGENTS.md", "skills", "rules", "prompts"] {
        let input = source.appendingPathComponent(name)
        guard manager.fileExists(atPath: input.path) else { continue }
        let resolved = try physicalURL(input)
        guard protectedRoots.allSatisfy({ !contains($0.path, resolved.path) }) else {
          throw CodexIsolatedLaunchError.overlappingDirectories
        }
        let destination = home.appendingPathComponent(name)
        if let existing = try? manager.destinationOfSymbolicLink(atPath: destination.path) {
          guard existing == resolved.path else { throw CodexIsolatedLaunchError.invalidDirectory }
          continue
        }
        if manager.fileExists(atPath: destination.path) { continue }
        do {
          try manager.createSymbolicLink(
            atPath: destination.path, withDestinationPath: resolved.path)
        } catch {
          throw CodexIsolatedLaunchError.invalidDirectory
        }
      }
    }

    private static func prepareConfigSnapshot(
      from source: URL?, in home: URL, protectedRoots: [URL]
    ) throws {
      let manager = FileManager.default
      let destination = home.appendingPathComponent("config.toml")
      if manager.fileExists(atPath: destination.path)
        || (try? manager.destinationOfSymbolicLink(atPath: destination.path)) != nil
      {
        try validateConfigSnapshot(destination)
        return
      }

      let temporary = home.appendingPathComponent(".config-\(UUID().uuidString)")
      defer { try? manager.removeItem(at: temporary) }
      do {
        if let input = source?.appendingPathComponent("config.toml"),
          manager.fileExists(atPath: input.path)
        {
          let resolved = try physicalURL(input)
          guard protectedRoots.allSatisfy({ !contains($0.path, resolved.path) }),
            try resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
          else { throw CodexIsolatedLaunchError.invalidSourceConfiguration }
          try manager.copyItem(at: resolved, to: temporary)
        } else {
          try Data().write(to: temporary, options: .withoutOverwriting)
        }
        guard temporary.path.withCString({ chmod($0, 0o400) }) == 0 else {
          throw CodexIsolatedLaunchError.invalidSourceConfiguration
        }
        try manager.moveItem(at: temporary, to: destination)
        try validateConfigSnapshot(destination)
      } catch let error as CodexIsolatedLaunchError {
        throw error
      } catch {
        throw CodexIsolatedLaunchError.invalidSourceConfiguration
      }
    }

    private static func validateConfigSnapshot(_ file: URL) throws {
      var info = stat()
      guard file.path.withCString({ lstat($0, &info) }) == 0,
        (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_uid == geteuid(),
        (info.st_mode & 0o777) == 0o400
      else { throw CodexIsolatedLaunchError.invalidSourceConfiguration }
    }

    private static func contains(_ directory: String, _ path: String) -> Bool {
      let root = directory.precomposedStringWithCanonicalMapping.lowercased()
      let item = path.precomposedStringWithCanonicalMapping.lowercased()
      return item == root || item.hasPrefix(root == "/" ? "/" : root + "/")
    }

    private static func overlaps(_ first: String, _ second: String) -> Bool {
      contains(first, second) || contains(second, first)
    }

    private static func quotedPath(_ path: String) throws -> String {
      guard !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
        throw CodexIsolatedLaunchError.invalidDirectory
      }
      return "\""
        + path.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func profile(workspace: URL, runtime: URL, allowsSubprocesses: Bool = false)
      throws -> String
    {
      let home = runtime.appendingPathComponent("home", isDirectory: true)
      return "(version 1)(allow default)(deny file-write*)"
        + "(allow file-write* (subpath \(try quotedPath(workspace.path)))"
        + " (subpath \(try quotedPath(runtime.path))) (literal \"/dev/null\")"
        + " (literal \"/dev/tty\"))"
        + "(deny file-write* (literal \(try quotedPath(home.path)))"
        + " (literal \(try quotedPath(home.appendingPathComponent("config.toml").path)))"
        + " (regex #\"/[.]codex(/.*)?$\"))"
        + (allowsSubprocesses ? "" : "(deny process-fork)")
    }

    private static func probe() -> Bool {
      guard FileManager.default.isExecutableFile(atPath: sandboxExecutable.path) else {
        return false
      }
      let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-bridge-isolation-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: temporary) }
      do {
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let base = try physicalURL(temporary)
        let workspace = try privateDirectory("workspace", in: base)
        let runtime = try privateDirectory("runtime", in: base)
        let home = try privateDirectory("home", in: runtime)
        let protected = try privateDirectory("protected", in: base)
        try prepareConfigSnapshot(from: nil, in: home, protectedRoots: [workspace, runtime])
        try FileManager.default.createSymbolicLink(
          at: workspace.appendingPathComponent("escape"), withDestinationURL: protected)
        let command = #"""
          set -eu
          : > "$1/allowed"
          : > "$2/allowed"
          if (: > "$3/outside") 2>/dev/null; then exit 41; fi
          if (: > "$1/escape/symlink") 2>/dev/null; then exit 42; fi
          /bin/sh -c 'if (: > "$1/child") 2>/dev/null; then exit 43; fi' sh "$3"
          if rm "$2/home/config.toml" 2>/dev/null; then exit 44; fi
          if mv "$2/home" "$2/home-moved" 2>/dev/null; then exit 45; fi
          if ln "$2/home/config.toml" "$1/config-link" 2>/dev/null; then
            if chmod u+w "$1/config-link" 2>/dev/null && (: > "$1/config-link") 2>/dev/null; then exit 48; fi
          fi
          mkdir "$1/nested"
          if mkdir "$1/.codex" 2>/dev/null; then exit 46; fi
          if mkdir "$1/nested/.codex" 2>/dev/null; then exit 47; fi
          : > "$2/home/session"
          """#
        let process = Process()
        process.executableURL = sandboxExecutable
        process.arguments = [
          "-p", try profile(workspace: workspace, runtime: runtime, allowsSubprocesses: true),
          "/bin/sh", "-c", command, "sh", workspace.path, runtime.path, protected.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
          kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        return process.terminationReason == .exit && process.terminationStatus == 0
      } catch {
        return false
      }
    }
  #else
    private static let availability = false
  #endif
}

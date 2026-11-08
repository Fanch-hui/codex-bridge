import Foundation

#if os(macOS)
  import Darwin
#endif

public enum WorkspaceProcessIsolationError: Error, Equatable, Sendable {
  case unavailable
  case invalidDirectory
  case overlappingDirectories
  case invalidExecutable
}

public struct WorkspaceIsolatedProcessConfiguration: Sendable {
  public let executableURL: URL
  public let arguments: [String]
  public let environment: [String: String]
  public let currentDirectoryURL: URL
}

/// Restricts a process and its descendants to the supplied writable directories.
public enum WorkspaceProcessIsolation {
  public static var isAvailable: Bool { availability }

  public static func prepare(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    workspaceRoot: URL,
    runtimeDirectory: URL,
    denyProcessFork: Bool = false
  ) throws -> WorkspaceIsolatedProcessConfiguration {
    #if os(macOS)
      guard isAvailable else { throw WorkspaceProcessIsolationError.unavailable }
      guard executableURL.isFileURL, executableURL.path.hasPrefix("/"),
        !executableURL.path.contains("\0")
      else { throw WorkspaceProcessIsolationError.invalidExecutable }
      let workspace = try existingDirectory(workspaceRoot)
      let runtime = try existingDirectory(runtimeDirectory)
      guard !overlaps(workspace.path, runtime.path) else {
        throw WorkspaceProcessIsolationError.overlappingDirectories
      }
      let home = try privateDirectory("home", in: runtime)
      let temporary = try privateDirectory("tmp", in: runtime)
      let cache = try privateDirectory("cache", in: runtime)
      let config = try privateDirectory("config", in: runtime)
      let data = try privateDirectory("data", in: runtime)
      let state = try privateDirectory("state", in: runtime)
      var privateEnvironment = environment
      privateEnvironment["HOME"] = home.path
      privateEnvironment["TMPDIR"] = temporary.path + "/"
      privateEnvironment["TMP"] = temporary.path
      privateEnvironment["TEMP"] = temporary.path
      privateEnvironment["XDG_CACHE_HOME"] = cache.path
      privateEnvironment["XDG_CONFIG_HOME"] = config.path
      privateEnvironment["XDG_DATA_HOME"] = data.path
      privateEnvironment["XDG_STATE_HOME"] = state.path
      return WorkspaceIsolatedProcessConfiguration(
        executableURL: sandboxExecutable,
        arguments: [
          "-p",
          try profile(workspace: workspace, runtime: runtime, denyProcessFork: denyProcessFork),
          executableURL.path,
        ]
          + arguments,
        environment: privateEnvironment,
        currentDirectoryURL: workspace)
    #else
      throw WorkspaceProcessIsolationError.unavailable
    #endif
  }

  #if os(macOS)
    private static let sandboxExecutable = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    private static let availability = probe()

    private static func existingDirectory(_ url: URL) throws -> URL {
      guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"),
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
        values.isDirectory == true, values.isSymbolicLink != true,
        let buffer = url.path.withCString({ realpath($0, nil) })
      else { throw WorkspaceProcessIsolationError.invalidDirectory }
      defer { free(buffer) }
      let resolved = URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
      _ = try quotedPath(resolved.path)
      return resolved
    }

    private static func privateDirectory(_ name: String, in root: URL) throws -> URL {
      let child = root.appendingPathComponent(name, isDirectory: true)
      if !FileManager.default.fileExists(atPath: child.path) {
        do {
          try FileManager.default.createDirectory(
            at: child, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
          guard (try? existingDirectory(child)) != nil else {
            throw WorkspaceProcessIsolationError.invalidDirectory
          }
        }
      }
      let resolved = try existingDirectory(child)
      guard contains(root.path, resolved.path), resolved.path != root.path else {
        throw WorkspaceProcessIsolationError.invalidDirectory
      }
      return resolved
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
        throw WorkspaceProcessIsolationError.invalidDirectory
      }
      return "\""
        + path.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func profile(
      workspace: URL, runtime: URL, denyProcessFork: Bool = false
    ) throws -> String {
      "(version 1)(allow default)(deny file-write*)"
        + "(allow file-write* (subpath \(try quotedPath(workspace.path)))"
        + " (subpath \(try quotedPath(runtime.path))) (literal \"/dev/null\")"
        + " (literal \"/dev/tty\"))"
        + (denyProcessFork ? "(deny process-fork)" : "")
    }

    private static func probe() -> Bool {
      guard FileManager.default.isExecutableFile(atPath: sandboxExecutable.path) else {
        return false
      }
      let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "bridge-workspace-isolation-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: temporary) }
      do {
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let base = try existingDirectory(temporary)
        let workspace = try privateDirectory("workspace", in: base)
        let runtime = try privateDirectory("runtime", in: base)
        let protected = try privateDirectory("protected", in: base)
        try Data("safe".utf8).write(to: protected.appendingPathComponent("original"))
        try FileManager.default.createSymbolicLink(
          at: workspace.appendingPathComponent("escape"), withDestinationURL: protected)
        let command = #"""
          set -eu
          : > "$1/allowed"
          : > "$2/allowed"
          if (: > "$3/outside") 2>/dev/null; then exit 41; fi
          if (: > "$1/escape/symlink") 2>/dev/null; then exit 42; fi
          /bin/sh -c 'if (: > "$1/child") 2>/dev/null; then exit 43; fi' sh "$3"
          if ln "$3/original" "$1/link" 2>/dev/null; then
            if (: > "$1/link") 2>/dev/null; then exit 44; fi
          fi
          if mv "$3/original" "$1/moved" 2>/dev/null; then exit 45; fi
          """#
        let process = Process()
        process.executableURL = sandboxExecutable
        process.arguments = [
          "-p", try profile(workspace: workspace, runtime: runtime),
          "/bin/sh", "-c", command, "sh", workspace.path, runtime.path, protected.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
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

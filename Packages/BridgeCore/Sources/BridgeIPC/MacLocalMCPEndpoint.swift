#if os(macOS)
  import CryptoKit
  import Darwin
  import Foundation

  /// Private bootstrap address shared by the app and its embedded service.
  public enum MacLocalMCPEndpoint {
    public static func socketPath(
      executableURL: URL? = Bundle.main.executableURL
    ) throws -> String {
      let directory = try installationDirectory(executableURL)
      let digest = SHA256.hash(data: Data(directory.path.utf8))
      let suffix = digest.prefix(10).map { String(format: "%02x", $0) }.joined()
      return "/private/tmp/codex-bridge-\(getuid())-\(suffix)/mcp.sock"
    }

    public static func serviceExecutableURL(from app: URL) throws -> URL {
      let directory = try executableDirectory(app)
      if directory.lastPathComponent == "MacOS",
        directory.deletingLastPathComponent().lastPathComponent == "Contents"
      {
        return directory.deletingLastPathComponent()
          .appendingPathComponent("Resources/CodexBridgeService")
      }
      return directory.appendingPathComponent("codex-bridge-service")
    }

    public static func appExecutableURL(from service: URL) throws -> URL {
      let directory = try executableDirectory(service)
      if directory.lastPathComponent == "Resources",
        directory.deletingLastPathComponent().lastPathComponent == "Contents"
      {
        return directory.deletingLastPathComponent().appendingPathComponent("MacOS/CodexBridge")
      }
      return directory.appendingPathComponent("CodexBridge")
    }

    public static func prepareDirectory(path: String) throws {
      guard path.hasPrefix("/"), !path.contains("\0") else {
        throw MacLocalMCPError.invalidPath
      }
      let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
      if mkdir(directory, 0o700) != 0, errno != EEXIST {
        throw MacLocalMCPError.system(errno)
      }
      var metadata = stat()
      guard lstat(directory, &metadata) == 0,
        metadata.st_uid == geteuid(), metadata.st_mode & S_IFMT == S_IFDIR,
        metadata.st_mode & 0o7777 == 0o700
      else { throw MacLocalMCPError.invalidIdentity }
    }

    private static func executableDirectory(_ executable: URL?) throws -> URL {
      guard let executable, executable.isFileURL, executable.path.hasPrefix("/"),
        !executable.path.contains("\0")
      else { throw MacLocalMCPError.invalidPath }
      return executable.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent()
    }

    private static func installationDirectory(_ executable: URL?) throws -> URL {
      let directory = try executableDirectory(executable)
      let contents = directory.deletingLastPathComponent()
      if ["MacOS", "Resources"].contains(directory.lastPathComponent),
        contents.lastPathComponent == "Contents"
      {
        return contents.deletingLastPathComponent()
      }
      return directory
    }
  }

  public enum MacLocalMCPError: Error, Sendable {
    case system(Int32)
    case invalidPath
    case invalidIdentity
    case invalidFrame
    case closed
    case timeout
  }
#endif

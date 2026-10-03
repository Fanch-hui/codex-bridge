#if os(Linux)
  import Foundation
  import Glibc

  public enum LinuxServiceEndpoint {
    public static func runtimeDirectory(
      environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
      let root =
        environment["XDG_RUNTIME_DIR"].flatMap { value in
          value.hasPrefix("/") ? value : nil
        } ?? "/run/user/\(getuid())"
      return URL(fileURLWithPath: root, isDirectory: true)
        .appendingPathComponent("CodexBridge", isDirectory: true)
    }

    public static var socketPath: String {
      runtimeDirectory().appendingPathComponent("service.sock").path
    }

    public static func executableURL(processID: Int32 = getpid()) -> URL? {
      var buffer = [UInt8](repeating: 0, count: 4096)
      let count = buffer.withUnsafeMutableBufferPointer { bytes in
        bytes.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
          readlink("/proc/\(processID)/exe", $0, bytes.count)
        }
      }
      guard count > 0, count < buffer.count else { return nil }
      return URL(fileURLWithPath: String(decoding: buffer[..<count], as: UTF8.self))
    }

    public static var serviceExecutableURL: URL? {
      executableURL()?.deletingLastPathComponent()
        .appendingPathComponent("codex-bridge-service")
    }

    public static func prepareDirectory(_ directory: URL) throws {
      if mkdir(directory.path, 0o700) != 0, errno != EEXIST {
        throw LinuxSocketError.system(errno)
      }
      var metadata = stat()
      guard lstat(directory.path, &metadata) == 0,
        metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == S_IFDIR,
        metadata.st_mode & 0o777 == 0o700
      else { throw LinuxSocketError.invalidIdentity }
    }
  }

  public enum LinuxSocketError: Error, Sendable {
    case system(Int32)
    case invalidIdentity
    case invalidPath
    case closed
    case invalidFrame
  }

  public enum LinuxSocketIdentity {
    public static func accepts(descriptor: Int32, executableNames: [String]) -> Bool {
      var credentials = PeerCredentials()
      var length = socklen_t(MemoryLayout<PeerCredentials>.size)
      guard getsockopt(descriptor, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0,
        credentials.uid == getuid(),
        let actual = LinuxServiceEndpoint.executableURL(processID: credentials.pid),
        let current = LinuxServiceEndpoint.executableURL()
      else { return false }
      let directory = current.deletingLastPathComponent().resolvingSymlinksInPath()
      return executableNames.contains { name in
        actual.resolvingSymlinksInPath()
          == directory.appendingPathComponent(name)
          .resolvingSymlinksInPath()
      }
    }

    private struct PeerCredentials {
      var pid: Int32 = 0
      var uid: UInt32 = 0
      var gid: UInt32 = 0
    }
  }
#endif

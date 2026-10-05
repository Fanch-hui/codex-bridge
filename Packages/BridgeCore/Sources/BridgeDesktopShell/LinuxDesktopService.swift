#if os(Linux)
  import BridgeIPC
  import Foundation
  import Glibc

  enum LinuxDesktopService {
    static func ensureRunning() -> Bool {
      if socketReady() { return true }
      guard let executable = LinuxServiceEndpoint.serviceExecutableURL,
        FileManager.default.isExecutableFile(atPath: executable.path)
      else { return false }
      let process = Process()
      process.executableURL = executable
      process.currentDirectoryURL = executable.deletingLastPathComponent()
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      do { try process.run() } catch { return false }
      for _ in 0..<50 {
        usleep(200_000)
        if socketReady() { return true }
        if !process.isRunning { return false }
      }
      return false
    }

    static func socketReady() -> Bool {
      let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
      guard descriptor >= 0 else { return false }
      defer { _ = Glibc.close(descriptor) }
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      let bytes = Array(LinuxServiceEndpoint.socketPath.utf8) + [0]
      guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
      withUnsafeMutableBytes(of: &address.sun_path) { target in
        target.copyBytes(from: bytes)
      }
      let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
      }
      return connected
        && LinuxSocketIdentity.accepts(
          descriptor: descriptor, executableNames: ["codex-bridge-service"])
    }

    static var registrationURL: URL {
      let environment = ProcessInfo.processInfo.environment
      let root =
        environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config").path
      return URL(fileURLWithPath: root).appendingPathComponent(
        "autostart/codex-bridge-service.desktop")
    }

    static func isRegistered() -> Bool {
      FileManager.default.fileExists(atPath: registrationURL.path)
    }

    static func register() throws {
      guard let executable = LinuxServiceEndpoint.serviceExecutableURL,
        FileManager.default.isExecutableFile(atPath: executable.path)
      else { throw CocoaError(.fileNoSuchFile) }
      let escaped = executable.path.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "`", with: "\\`")
        .replacingOccurrences(of: "$", with: "\\$")
        .replacingOccurrences(of: "%", with: "%%")
      guard !escaped.contains("\n"), !escaped.contains("\r") else {
        throw CocoaError(.fileWriteInvalidFileName)
      }
      let entry = """
        [Desktop Entry]
        Type=Application
        Name=Codex Bridge Service
        Exec="\(escaped)"
        Terminal=false
        X-GNOME-Autostart-enabled=true
        """
      try FileManager.default.createDirectory(
        at: registrationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try entry.write(to: registrationURL, atomically: true, encoding: .utf8)
    }

    static func unregister() throws {
      if isRegistered() { try FileManager.default.removeItem(at: registrationURL) }
    }
  }
#endif

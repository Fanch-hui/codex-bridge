#if os(Linux)
  import Foundation

  enum LinuxNetworkSandbox {
    static let executablePath = "/usr/bin/bwrap"
    private static let prefix = [
      executablePath, "--die-with-parent", "--unshare-net", "--unshare-pid",
      "--bind", "/", "/", "--proc", "/proc", "--dev", "/dev", "--",
    ]

    static func arguments(command: [String]) -> [String] {
      prefix + command
    }

    static let isAvailable: Bool = {
      guard FileManager.default.isExecutableFile(atPath: executablePath) else { return false }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executablePath)
      process.arguments = Array(arguments(command: ["/usr/bin/true"]).dropFirst())
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      do {
        try process.run()
        process.waitUntilExit()
        return process.terminationReason == .exit && process.terminationStatus == 0
      } catch {
        return false
      }
    }()
  }
#endif

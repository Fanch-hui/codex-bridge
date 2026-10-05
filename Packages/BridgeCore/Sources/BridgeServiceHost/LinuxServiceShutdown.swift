#if os(Linux)
  import BridgeIPC

  enum LinuxServiceShutdown {
    static func requestAndWait(requireIdle: Bool = false) async throws {
      try await LinuxServiceControl.shutdownAndWait(requireIdle: requireIdle)
    }
  }
#endif

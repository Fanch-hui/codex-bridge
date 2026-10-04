#if os(Linux)
  import BridgeIPC

  public enum LinuxApplicationControl {
    public static func ensureServiceRunning() async -> Bool {
      guard LinuxDesktopService.ensureRunning() else { return false }
      let client = BridgeServiceClient(transport: ServiceTransportFactory.defaultTransport())
      do {
        _ = try await client.status()
        await client.invalidate()
        return true
      } catch {
        await client.invalidate()
        return false
      }
    }

    public static func shutdownService() async -> Bool {
      do {
        try await LinuxServiceControl.shutdownAndWait()
        return true
      } catch {
        return false
      }
    }
  }
#endif

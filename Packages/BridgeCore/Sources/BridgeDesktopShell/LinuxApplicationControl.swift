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
      let client = BridgeServiceClient(transport: ServiceTransportFactory.defaultTransport())
      do {
        _ = try await client.shutdownService()
        await client.invalidate()
        return true
      } catch {
        await client.invalidate()
        return false
      }
    }
  }
#endif

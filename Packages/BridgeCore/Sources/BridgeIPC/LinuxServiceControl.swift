#if os(Linux)
  import Foundation
  import Glibc

  public enum LinuxServiceControl {
    public static func shutdownAndWait(requireIdle: Bool = false) async throws {
      let client = BridgeServiceClient(transport: ServiceTransportFactory.defaultTransport())
      let response: IPCServiceShutdownResponse
      do {
        response =
          if requireIdle {
            try await client.shutdownServiceIfIdle()
          } else {
            try await client.shutdownService()
          }
      } catch BridgeServiceClientError.unavailable {
        await client.invalidate()
        if requireIdle { throw BridgeServiceClientError.unavailable }
        return
      } catch {
        await client.invalidate()
        throw error
      }
      await client.invalidate()
      guard let expected = LinuxServiceEndpoint.serviceExecutableURL,
        response.imagePath == expected.path,
        let processID = Int32(exactly: response.processID), processID > 1,
        processID != getpid()
      else { throw LinuxSocketError.invalidIdentity }
      let startTime = processStartTime(processID)
      for _ in 0..<300 {
        guard LinuxServiceEndpoint.executableURL(processID: processID)?.path == expected.path,
          processStartTime(processID) == startTime
        else { return }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw LinuxSocketError.system(ETIMEDOUT)
    }

    private static func processStartTime(_ processID: Int32) -> String? {
      guard let data = FileManager.default.contents(atPath: "/proc/\(processID)/stat"),
        let status = String(data: data, encoding: .utf8),
        let end = status.lastIndex(of: ")")
      else { return nil }
      let fields = status[status.index(after: end)...].split(separator: " ")
      return fields.count > 19 ? String(fields[19]) : nil
    }
  }
#endif

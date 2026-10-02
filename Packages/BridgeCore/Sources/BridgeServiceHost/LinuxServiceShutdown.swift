#if os(Linux)
  import BridgeIPC
  import Foundation
  import Glibc

  enum LinuxServiceShutdown {
    static func requestAndWait() async throws {
      let client = BridgeServiceClient(transport: ServiceTransportFactory.defaultTransport())
      let response: IPCServiceShutdownResponse
      do {
        response = try await client.shutdownService()
      } catch BridgeServiceClientError.unavailable {
        await client.invalidate()
        return
      } catch {
        await client.invalidate()
        throw error
      }
      await client.invalidate()
      guard let current = LinuxServiceEndpoint.executableURL(),
        response.imagePath == current.path, response.processID > 0,
        response.processID != UInt32(getpid())
      else { throw LinuxSocketError.invalidIdentity }
      let processID = Int32(exactly: response.processID)
      guard let processID else { throw LinuxSocketError.invalidIdentity }
      for _ in 0..<300 {
        guard LinuxServiceEndpoint.executableURL(processID: processID)?.path == current.path else {
          return
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw LinuxSocketError.system(ETIMEDOUT)
    }
  }
#endif

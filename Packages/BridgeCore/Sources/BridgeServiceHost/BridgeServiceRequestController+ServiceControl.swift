import BridgeIPC
import Foundation

#if os(Windows)
  import WinSDK
#elseif os(Linux)
  import Glibc
#endif

extension BridgeServiceRequestController {
  #if os(Windows) || os(Linux)
    func handleShutdownService(_ request: BridgeServiceIPCRequest) throws -> Data {
      guard request.payload == nil else {
        throw BridgeServiceIPCCodecError.invalidMessage
      }
      #if os(Windows)
        let imagePath = try WindowsProcessIdentity.currentImagePath()
        let processID = GetCurrentProcessId()
      #else
        guard let imagePath = LinuxServiceEndpoint.executableURL()?.path else {
          throw LinuxSocketError.invalidIdentity
        }
        let processID = UInt32(getpid())
      #endif
      return try BridgeServiceIPCCodec.success(
        requestID: request.requestID,
        payload: IPCServiceShutdownResponse(
          processID: processID,
          imagePath: imagePath
        )
      )
    }
  #endif
}

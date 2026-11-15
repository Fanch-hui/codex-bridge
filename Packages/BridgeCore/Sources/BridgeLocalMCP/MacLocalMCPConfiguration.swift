#if os(macOS)
  import BridgeIPC
  import Darwin
  import Foundation

  enum MacLocalMCPConfiguration {
    static func load() async throws -> IPCLocalMCPConnectionResponse {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          do { continuation.resume(returning: try read()) } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    }

    static func read(
      path: String? = nil, expectedService: URL? = nil
    ) throws -> IPCLocalMCPConnectionResponse {
      let path = try path ?? MacLocalMCPEndpoint.socketPath()
      guard let executable = Bundle.main.executableURL else {
        throw MacLocalMCPError.invalidIdentity
      }
      let service =
        try expectedService ?? MacLocalMCPEndpoint.serviceExecutableURL(from: executable)
      let channel = try MacLocalMCPChannel.connect(path: path)
      defer { channel.close() }
      guard
        MacLocalMCPChannel.acceptsPeer(
          descriptor: channel.descriptor, expectedExecutableURL: service
        )
      else { throw MacLocalMCPError.invalidIdentity }
      let requestID = UUID().uuidString.lowercased()
      let request = try BridgeServiceIPCCodec.request(
        operation: .getLocalMCPConnection,
        payload: IPCMCPClientRequest(clientID: "google.gemini"), requestID: requestID
      )
      try channel.writeFrame(request)
      return try BridgeServiceIPCCodec.decodeResponse(
        IPCLocalMCPConnectionResponse.self, data: channel.readFrame(timeoutSeconds: 120),
        requestID: requestID)
    }
  }
#endif

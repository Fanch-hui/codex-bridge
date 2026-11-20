import Foundation

public enum ServiceFrameKind {
  public static let legacyRequest: UInt8 = 0
  public static let legacyResponse: UInt8 = 1
  public static let streamPush: UInt8 = 2
  public static let multiplexedRequest: UInt8 = 3
  public static let multiplexedResponse: UInt8 = 4

  public static func maximumPayloadBytes(for kind: UInt8) -> Int {
    if kind == multiplexedRequest || kind == multiplexedResponse {
      return BridgeServiceIPC.maximumMessageBytes + ServiceMultiplexedFrame.tagByteCount
    }
    return BridgeServiceIPC.maximumMessageBytes
  }
}

public enum ServiceMultiplexedFrame {
  public static let tagByteCount = MemoryLayout<UInt64>.size

  public static func encode(tag: UInt64, payload: Data) -> Data {
    var littleEndian = tag.littleEndian
    var combined = Data(capacity: tagByteCount + payload.count)
    withUnsafeBytes(of: &littleEndian) { combined.append(contentsOf: $0) }
    combined.append(payload)
    return combined
  }

  public static func decode(_ data: Data) -> (tag: UInt64, payload: Data)? {
    guard data.count >= tagByteCount else { return nil }
    let tag = data.withUnsafeBytes { raw in
      raw.loadUnaligned(as: UInt64.self).littleEndian
    }
    let bodyStart = data.index(data.startIndex, offsetBy: tagByteCount)
    return (tag, Data(data[bodyStart...]))
  }

  /// Safe, side-effect-free requests that may fall back once to legacy FIFO framing
  /// when a newer shell connects to an older background service during an upgrade.
  public static func allowsLegacyFallback(for requestPayload: Data) -> Bool {
    guard let request = try? BridgeServiceIPCCodec.decodeRequest(requestPayload) else {
      return false
    }
    switch request.operation {
    case .status, .getLocalMCPConnection, .shutdownService, .shutdownServiceIfIdle:
      return true
    default:
      return false
    }
  }
}

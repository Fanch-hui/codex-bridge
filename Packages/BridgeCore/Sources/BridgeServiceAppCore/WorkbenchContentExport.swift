import BridgeIPC
import BridgeSecurity
import Foundation

public struct WorkbenchContentExportRequest: Decodable, Sendable {
  public let sessionId: String
  public let seq: Int64
  public let field: String
}

/// Streams a selected record to a sibling temporary file before replacing the destination.
public enum WorkbenchContentExport {
  private static let chunkSize = 65_536
  private struct Query: Encodable {
    let sessionId: String
    let seq: Int64
    let field: String
    let offset: Int
    let limit: Int
  }
  private struct Chunk: Decodable {
    let text: String
    let nextOffset: Int?
    let totalBytes: Int
  }
  private enum Failure: LocalizedError {
    case invalidRequest, invalidChunk, temporaryFile
    var errorDescription: String? {
      switch self {
      case .invalidRequest: "会话内容请求无效。"
      case .invalidChunk: "会话内容读取不完整，请重试。"
      case .temporaryFile: "无法在所选位置准备导出文件。"
      }
    }
  }

  public static func request(from json: String) throws -> WorkbenchContentExportRequest {
    let request = try JSONDecoder().decode(
      WorkbenchContentExportRequest.self, from: Data(json.utf8))
    guard !request.sessionId.isEmpty, request.sessionId.utf8.count <= 256,
      !request.sessionId.contains("\0"), request.seq >= 0,
      ["message.text", "reasoning", "tool.input", "tool.output"].contains(request.field)
    else { throw Failure.invalidRequest }
    return request
  }

  public static func export(
    _ request: WorkbenchContentExportRequest, to destination: URL,
    client: any BridgeServiceClientProtocol
  ) async throws {
    try await export(request, to: destination) { action, payload in
      try await client.embeddedDSH(.init(action: action, payloadJSON: payload)).resultJSON
    }
  }

  static func export(
    _ request: WorkbenchContentExportRequest, to destination: URL,
    invoke: @Sendable (String, String) async throws -> String
  ) async throws {
    let parent = destination.deletingLastPathComponent()
    let temporary = parent.appendingPathComponent(".bridge-export-\(UUID().uuidString)")
    let manager = FileManager.default
    guard manager.createFile(atPath: temporary.path, contents: nil) else {
      throw Failure.temporaryFile
    }
    defer { try? manager.removeItem(at: temporary) }
    let file = try FileHandle(forWritingTo: temporary)
    do {
      var offset = 0
      var expectedSize: Int?
      while true {
        try Task.checkCancellation()
        let query = Query(
          sessionId: request.sessionId, seq: request.seq, field: request.field,
          offset: offset, limit: chunkSize)
        let payload = try JSONEncoder().encode(query)
        let response = try await invoke("session.content", String(decoding: payload, as: UTF8.self))
        let chunk = try JSONDecoder().decode(Chunk.self, from: Data(response.utf8))
        let bytes = Data(chunk.text.utf8)
        guard chunk.totalBytes >= 0, bytes.count <= chunkSize, offset <= chunk.totalBytes,
          bytes.count <= chunk.totalBytes - offset,
          expectedSize == nil || expectedSize == chunk.totalBytes
        else { throw Failure.invalidChunk }
        expectedSize = chunk.totalBytes
        try file.write(contentsOf: bytes)
        offset += bytes.count
        if let next = chunk.nextOffset {
          guard !bytes.isEmpty, next == offset, next < chunk.totalBytes else {
            throw Failure.invalidChunk
          }
        } else {
          guard offset == chunk.totalBytes else { throw Failure.invalidChunk }
          break
        }
      }
      try file.synchronize()
      try file.close()
      try FileReplacement.publish(temporary, at: destination)
    } catch {
      try? file.close()
      throw error
    }
  }
}

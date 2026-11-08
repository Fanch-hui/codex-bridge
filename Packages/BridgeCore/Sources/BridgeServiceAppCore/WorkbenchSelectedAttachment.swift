import BridgeAgentCore
import BridgeIPC
import BridgeSecurity
import Foundation

/// Imports the immutable bytes of an image explicitly selected through a platform file panel.
public enum WorkbenchSelectedAttachment {
  private static let chunkSize = 512 * 1_024
  private struct Item: Encodable {
    let name: String
    let mimeType: String
    let byteCount: Int
  }
  private struct Begin: Encodable { let items: [Item] }
  private struct Upload: Codable { let uploadID: String }
  private struct Chunk: Encodable {
    let uploadID: String
    let index: Int
    let offset: Int
    let data: String
  }
  private struct Progress: Decodable { let nextOffset: Int }
  private enum Failure: LocalizedError {
    case invalidProgress
    var errorDescription: String? { "图片传输进度未确认，请重试。" }
  }

  public static func importSelected(at path: String, client: any BridgeServiceClientProtocol)
    async throws
    -> String
  {
    try await importSelected(at: path) { action, payload in
      try await client.embeddedDSH(.init(action: action, payloadJSON: payload)).resultJSON
    }
  }

  static func importSelected(
    at path: String, invoke: @Sendable (String, String) async throws -> String
  ) async throws -> String {
    let data = try SecureFileArtifactReader.read(
      at: path, maximumBytes: AgentImageAttachmentLimits.maximumBytesPerAttachment)
    let mimeType = try SecureProjectImageReader.mimeType(of: data)
    let item = Item(
      name: URL(fileURLWithPath: path).lastPathComponent, mimeType: mimeType,
      byteCount: data.count)
    let start = try await request("attachments.import.begin", Begin(items: [item]), invoke: invoke)
    let upload = try JSONDecoder().decode(Upload.self, from: Data(start.utf8))
    do {
      var offset = 0
      while offset < data.count {
        try Task.checkCancellation()
        let next = min(offset + chunkSize, data.count)
        let chunk = Chunk(
          uploadID: upload.uploadID, index: 0, offset: offset,
          data: data.subdata(in: offset..<next).base64EncodedString())
        let response = try await request("attachments.import.append", chunk, invoke: invoke)
        let progress = try JSONDecoder().decode(Progress.self, from: Data(response.utf8))
        guard progress.nextOffset == next else { throw Failure.invalidProgress }
        offset = next
      }
      return try await request("attachments.import.finish", upload, invoke: invoke)
    } catch {
      _ = try? await request("attachments.import.cancel", upload, invoke: invoke)
      throw error
    }
  }

  private static func request<T: Encodable>(
    _ action: String, _ payload: T, invoke: @Sendable (String, String) async throws -> String
  ) async throws -> String {
    let input = try JSONEncoder().encode(payload)
    return try await invoke(action, String(decoding: input, as: UTF8.self))
  }
}

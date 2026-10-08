import BridgeProcess
import Foundation

struct JSONLineParser: Sendable {
  private var decoder: ProgressJSONLineDecoder
  private let maximumLineBytes: Int

  init(maximumLineBytes: Int = 8 * 1024 * 1024) {
    self.maximumLineBytes = maximumLineBytes
    decoder = ProgressJSONLineDecoder(dialect: .codex, maximumFrameBytes: maximumLineBytes)
  }

  mutating func ingest(_ data: Data) throws -> [JSONValue] {
    try frames { try $0.append(data) }
  }

  mutating func finish() throws -> [JSONValue] {
    try frames { try $0.finish() }
  }

  private mutating func frames(
    _ operation: (inout ProgressJSONLineDecoder) throws -> [Data]
  ) throws -> [JSONValue] {
    let values: [Data]
    do {
      values = try operation(&decoder)
    } catch {
      throw CodexRPCError.protocolLineTooLarge(maximumBytes: maximumLineBytes)
    }
    return try values.compactMap { try decode($0) }
  }

  private func decode(_ line: Data) throws -> JSONValue? {
    let trimmed = line.trimmingASCIIWhitespace()
    guard !trimmed.isEmpty else { return nil }
    guard String(data: trimmed, encoding: .utf8) != nil else {
      throw CodexRPCError.invalidUTF8
    }

    do {
      return try JSONDecoder().decode(JSONValue.self, from: trimmed)
    } catch {
      let preview = String(decoding: trimmed.prefix(160), as: UTF8.self)
      guard preview.first == "{" else {
        throw CodexRPCError.protocolContamination(preview)
      }
      throw CodexRPCError.malformedMessage(error.localizedDescription)
    }
  }
}

extension Data {
  fileprivate func trimmingASCIIWhitespace() -> Data {
    let whitespace: Set<UInt8> = [0x09, 0x0A, 0x0D, 0x20]
    guard let first = firstIndex(where: { !whitespace.contains($0) }) else {
      return Data()
    }
    let last = lastIndex(where: { !whitespace.contains($0) }) ?? first
    return Data(self[first...last])
  }
}

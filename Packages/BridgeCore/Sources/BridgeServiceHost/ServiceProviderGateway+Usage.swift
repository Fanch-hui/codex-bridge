import BridgeACP
import Foundation

/// Collects only provider-reported token counts while leaving the response stream unchanged.
actor ServiceGatewayUsage {
  private let stream: Bool
  private let maximumBytes = 4 * 1_024 * 1_024
  private var buffer = Data()
  private var event = Data()
  private var discardingLine = false
  private var discardingEvent = false
  private var unreadable = false
  private(set) var upstreamFailed = false
  private var counts: [String: ACPJSONValue] = [:]

  init(stream: Bool) { self.stream = stream }

  func receive(_ bytes: Data) {
    guard !bytes.isEmpty else { return }
    if !stream {
      guard !unreadable else { return }
      guard buffer.count + bytes.count <= maximumBytes else {
        buffer.removeAll()
        unreadable = true
        return
      }
      buffer.append(bytes)
      return
    }
    buffer.append(bytes)
    while let newline = buffer.firstIndex(of: 10) {
      let line = Data(buffer[..<newline])
      buffer.removeSubrange(...newline)
      if discardingLine {
        discardingLine = false
        continue
      }
      receiveLine(line)
    }
    if buffer.count > maximumBytes {
      buffer.removeAll()
      discardingLine = true
      discardingEvent = true
      event.removeAll()
      unreadable = true
    }
  }

  func receiveReported(_ value: ACPJSONValue) {
    collect(value)
  }

  func presentation() -> ACPJSONValue {
    if !stream, !buffer.isEmpty { collectJSON(buffer) }
    if stream, !buffer.isEmpty, !discardingLine { receiveLine(buffer) }
    if stream, !event.isEmpty, !discardingEvent { collectJSON(event) }
    guard !counts.isEmpty else {
      return .object(["status": .string(unreadable ? "unavailable" : "not_provided")])
    }
    return .object(
      counts.merging(["status": .string(unreadable ? "partial" : "provided")]) { value, _ in
        value
      })
  }

  private func receiveLine(_ raw: Data) {
    var line = raw
    if line.last == 13 { line.removeLast() }
    if line.isEmpty {
      if !discardingEvent, !event.isEmpty { collectJSON(event) }
      event.removeAll()
      discardingEvent = false
      return
    }
    guard !discardingEvent, line.starts(with: Data("data:".utf8)) else { return }
    line.removeFirst(5)
    if line.first == 32 { line.removeFirst() }
    if !event.isEmpty { event.append(10) }
    guard event.count + line.count <= maximumBytes else {
      event.removeAll()
      discardingEvent = true
      unreadable = true
      return
    }
    event.append(line)
  }

  private func collectJSON(_ data: Data) {
    guard let value = try? JSONDecoder().decode(ACPJSONValue.self, from: data) else { return }
    let type = value["type"]?.stringValue
    if type == "error" || type == "response.failed" || type == "response.incomplete"
      || (value["error"] != nil && value["error"] != .null)
    {
      upstreamFailed = true
    }
    if let usage = value["usage"] { collect(usage) }
    if let usage = value["response"]?["usage"] { collect(usage) }
    if let usage = value["message"]?["usage"] { collect(usage) }
  }

  private func collect(_ usage: ACPJSONValue) {
    let fields: [(String, [ACPJSONValue?])] = [
      ("inputTokens", [usage["input_tokens"], usage["prompt_tokens"]]),
      ("outputTokens", [usage["output_tokens"], usage["completion_tokens"]]),
      ("totalTokens", [usage["total_tokens"]]),
      (
        "cacheReadTokens",
        [
          usage["cache_read_input_tokens"], usage["input_tokens_details"]?["cached_tokens"],
          usage["prompt_tokens_details"]?["cached_tokens"],
        ]
      ),
      (
        "cacheWriteTokens",
        [
          usage["cache_creation_input_tokens"],
          usage["input_tokens_details"]?["cache_write_tokens"],
          usage["prompt_tokens_details"]?["cache_write_tokens"],
        ]
      ),
      (
        "reasoningTokens",
        [
          usage["output_tokens_details"]?["reasoning_tokens"],
          usage["completion_tokens_details"]?["reasoning_tokens"],
        ]
      ),
    ]
    for (name, values) in fields {
      if let count = values.compactMap({ $0?.intValue }).first(where: { $0 >= 0 }) {
        counts[name] = .integer(Int64(count))
      }
    }
  }
}

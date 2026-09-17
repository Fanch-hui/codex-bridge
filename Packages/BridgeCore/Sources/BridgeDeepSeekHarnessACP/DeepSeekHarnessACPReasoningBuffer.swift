import BridgeAgentCore
import Foundation

struct DeepSeekHarnessACPReasoningBuffer {
  private var content = ""
  private var index: UInt64 = 0

  mutating func append(_ text: String) throws -> AgentContentUpdate? {
    guard !text.isEmpty else { return nil }
    let baseLength = content.utf8.count
    guard text.utf8.count <= DeepSeekHarnessACPConstants.maximumFinalTextBytes - baseLength else {
      throw DeepSeekHarnessACPError.oversizedFrame
    }
    content.append(text)
    return try AgentContentUpdate(
      key: key, role: .assistant, kind: .reasoning, mode: .delta,
      content: text, baseContentLength: baseLength, isFinal: false, authoritative: false
    )
  }

  mutating func finish() throws -> AgentContentUpdate? {
    guard !content.isEmpty else { return nil }
    let update = try AgentContentUpdate(
      key: key, role: .assistant, kind: .reasoning, mode: .full,
      content: content, baseContentLength: nil, isFinal: true, authoritative: true
    )
    content = ""
    index += 1
    return update
  }

  private var key: String {
    index == 0 ? "reasoning:assistant" : "reasoning:assistant:\(index)"
  }
}

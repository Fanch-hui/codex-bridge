import BridgeAgentCore
import Foundation

struct DeepSeekHarnessACPReasoningBuffer {
  private var content = AgentProgressTextBuffer()
  private var index: UInt64 = 0

  mutating func append(_ text: String) throws -> AgentContentUpdate? {
    try content.append(text, key: key, role: .assistant, kind: .reasoning)
  }

  mutating func finish() throws -> AgentContentUpdate? {
    guard !content.content.isEmpty else { return nil }
    let update = try AgentContentUpdate(
      key: key, role: .assistant, kind: .reasoning, mode: .full,
      content: content.content, baseContentLength: nil, isFinal: true, authoritative: true
    )
    content = AgentProgressTextBuffer()
    index += 1
    return update
  }

  private var key: String {
    index == 0 ? "reasoning:assistant" : "reasoning:assistant:\(index)"
  }
}

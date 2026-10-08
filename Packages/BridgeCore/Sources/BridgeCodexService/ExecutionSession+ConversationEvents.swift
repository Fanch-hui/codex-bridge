import BridgeCodexRPC
import BridgeSecurity

extension ExecutionSession {
  func receiveAgentMessageDelta(_ notification: RPCNotification) async {
    do {
      guard case .agentMessageDelta(let delta) = try notification.decodedCodexNotification()
      else {
        throw ExecutionServiceError.protocolViolation("agent message delta")
      }
      try requireActiveEvidence(threadID: delta.threadId, turnID: delta.turnId)
      guard isPrimaryBinding(threadID: delta.threadId, turnID: delta.turnId) else { return }
      try ExecutionValidation.streamDelta(
        delta.delta, field: "agentMessageDelta.delta", maximumBytes: Int.max)
      let event = try ExecutionAgentMessageDelta(
        threadID: delta.threadId,
        turnID: delta.turnId,
        itemID: delta.itemId,
        delta: OutboundContentSecurity.redacted(delta.delta, maximumUTF8Bytes: 64 * 1_024)
      )
      await yield(.agentMessageDelta(event))
    } catch {
      await fail(
        code: "invalid_agent_delta",
        summary: "Codex emitted an invalid agent message delta."
      )
    }
  }

  func receiveReasoningTextDelta(_ notification: RPCNotification) async {
    do {
      guard case .reasoningTextDelta(let delta) = try notification.decodedCodexNotification()
      else {
        throw ExecutionServiceError.protocolViolation("reasoning text delta")
      }
      try requireActiveEvidence(threadID: delta.threadId, turnID: delta.turnId)
      guard isPrimaryBinding(threadID: delta.threadId, turnID: delta.turnId) else { return }
      try ExecutionValidation.streamDelta(
        delta.delta, field: "reasoningDelta.delta", maximumBytes: Int.max)
      let event = try ExecutionReasoningDelta(
        threadID: delta.threadId,
        turnID: delta.turnId,
        itemID: delta.itemId,
        delta: OutboundContentSecurity.redacted(delta.delta, maximumUTF8Bytes: 64 * 1_024)
      )
      await yield(.reasoningDelta(event))
    } catch {
      await fail(
        code: "invalid_reasoning_delta",
        summary: "Codex emitted an invalid reasoning delta."
      )
    }
  }

  func receiveMcpToolCallProgress(_ notification: RPCNotification) async {
    do {
      guard case .mcpToolCallProgress(let progress) = try notification.decodedCodexNotification()
      else {
        throw ExecutionServiceError.protocolViolation("mcp tool call progress")
      }
      try requireActiveEvidence(threadID: progress.threadId, turnID: progress.turnId)
      guard isPrimaryBinding(threadID: progress.threadId, turnID: progress.turnId) else { return }
      guard Self.isSafeWireIdentifier(progress.itemId) else {
        throw ExecutionServiceError.protocolViolation("tool call progress item")
      }
      await yield(
        .toolCallProgress(
          itemID: progress.itemId,
          progress: OutboundContentSecurity.redacted(progress.message, maximumUTF8Bytes: 64 * 1_024)
        ))
    } catch {
      await fail(
        code: "invalid_tool_progress",
        summary: "Codex emitted invalid tool call progress."
      )
    }
  }
}

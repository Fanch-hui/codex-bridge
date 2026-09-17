import BridgeAgentCore

extension DeepSeekHarnessACPEventNormalizer {
  func normalizeForExecution(
    _ clientEnvelope: DeepSeekHarnessACPClientEventEnvelope
  ) throws -> [AgentEventEnvelope] {
    var events: [AgentEventEnvelope] = []
    switch clientEnvelope.event {
    case .textDelta, .toolUpdated:
      if let reasoning = try finalizeReasoning() { events.append(reasoning) }
    default:
      break
    }
    if case .toolUpdated = clientEnvelope.event,
      let finalizedContent = try finalizeCurrentContent()
    {
      events.append(finalizedContent)
    }
    if let event = try normalize(clientEnvelope) {
      events.append(event)
    }
    return events
  }
}

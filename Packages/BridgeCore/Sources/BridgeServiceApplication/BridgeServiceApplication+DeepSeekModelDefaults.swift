import BridgeAgentCore

extension BridgeServiceApplication {
  func reconcileDeepSeekHarnessModelDefaults(
    models: [AgentModelDescriptor], deadline: ContinuousClock.Instant
  ) async throws {
    guard let modelID = try await settings.string(for: .deepSeekHarnessDefaultModel) else {
      return
    }
    let effort = try await settings.string(for: .deepSeekHarnessDefaultEffort)
    let selected = models.first { $0.id == modelID }
    let clearEffort =
      selected == nil
      || (selected?.reasoningCapabilitiesAvailable == true
        && effort.map { selected?.supportedReasoningEfforts.contains($0) != true } == true)
    guard selected == nil || clearEffort else { return }
    _ = try await serviceSetAgentModelDefault(
      providerID: .deepSeekHarness, model: selected == nil ? nil : modelID,
      permissionMode: nil, effort: nil, updateEffort: clearEffort, deadline: deadline)
  }
}

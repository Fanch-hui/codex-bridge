import BridgeAgentCore
import Foundation

extension DeepSeekHarnessACPProvider {
  func applyRequestedSelection(
    request: AgentExecutionRequest,
    session: DeepSeekHarnessACPSession,
    client: DeepSeekHarnessACPClient
  ) async throws {
    var options = session.configOptions
    if request.requestedSessionID == nil
      && !options.contains(where: { $0.id == "model" || $0.category == "model" })
    {
      return
    }
    if let requestedModel = request.model {
      let modelOption = try modelOption(in: options)
      let wireValue = try modelWireValue(for: requestedModel, option: modelOption)
      options = try await client.setSessionConfigOption(
        sessionID: session.id,
        configID: modelOption.id,
        value: wireValue
      )
    }
    if let requestedEffort = request.effort {
      let effortOption = try effortOption(in: options)
      guard effortOption.values.contains(where: { $0.value == requestedEffort }) else {
        throw AgentRuntimeError.invalidRequest("request.effort")
      }
      _ = try await client.setSessionConfigOption(
        sessionID: session.id,
        configID: effortOption.id,
        value: requestedEffort
      )
    }
  }

  private func modelOption(
    in options: [DeepSeekHarnessACPConfigOption]
  ) throws -> DeepSeekHarnessACPConfigOption {
    guard
      let option = options.first(where: {
        $0.id == "model" || $0.category == "model"
      })
    else {
      throw AgentRuntimeError.capabilityUnavailable(.modelSelection)
    }
    return option
  }

  private func effortOption(
    in options: [DeepSeekHarnessACPConfigOption]
  ) throws -> DeepSeekHarnessACPConfigOption {
    guard
      let option = options.first(where: {
        $0.id == "effort" || $0.id == "reasoning_effort" || $0.category == "thought_level"
      })
    else {
      throw AgentRuntimeError.capabilityUnavailable(.effortSelection)
    }
    return option
  }

  private func modelWireValue(
    for requestedModel: String,
    option: DeepSeekHarnessACPConfigOption
  ) throws -> String {
    try DeepSeekHarnessACPModelRoutes.wireValue(for: requestedModel, option: option)
  }
}

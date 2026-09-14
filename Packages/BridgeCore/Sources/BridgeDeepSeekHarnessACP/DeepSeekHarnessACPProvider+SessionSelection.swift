import BridgeAgentCore
import Foundation

extension DeepSeekHarnessACPProvider {
  func applyRequestedSelection(
    request: AgentExecutionRequest,
    session: DeepSeekHarnessACPSession,
    client: DeepSeekHarnessACPClient
  ) async throws {
    guard request.requestedSessionID != nil else { return }
    var options = session.configOptions
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
    let normalized =
      requestedModel.hasPrefix("opencode-go/")
      ? String(requestedModel.dropFirst("opencode-go/".count))
      : requestedModel
    if let value = option.values.first(where: { $0.value == requestedModel }) {
      return value.value
    }
    if let value = option.values.first(where: {
      guard let route = try? JSONDecoder().decode([String].self, from: Data($0.value.utf8))
      else { return false }
      return route.count == 2 && route.last == normalized
    }) {
      return value.value
    }
    throw AgentRuntimeError.modelUnavailable(requestedModel)
  }
}

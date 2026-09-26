import BridgeAgentCore
import Foundation

extension PiRPCProvider {
  public func models(installation: AgentInstallation, projectRoot: String?) async throws
    -> [AgentModelDescriptor]
  {
    try await models(installation: installation, projectRoot: projectRoot, selectedModelID: nil)
  }

  public func models(
    installation: AgentInstallation, projectRoot _: String?, selectedModelID: String?
  )
    async throws -> [AgentModelDescriptor]
  {
    let profile = try PiRuntimeProfile.make(
      installation: installation, request: nil, configuration: configuration)
    let client = try makeClient(profile)
    do {
      let state = try await initialize(client, profile: profile)
      let values = try await availableModels(client)
      guard !values.isEmpty else {
        throw AgentRuntimeError.modelUnavailable("pi.no_configured_model")
      }
      let current = state["model"]
      let selected: PiModelKey?
      if let selectedModelID {
        selected = try PiModelKey(rawValue: selectedModelID)
      } else if let provider = current?["provider"]?.stringValue,
        let id = current?["id"]?.stringValue
      {
        selected = try PiModelKey(provider: provider, modelID: id)
      } else {
        selected = nil
      }
      if let selected { try await selectModel(try selected.encoded(), client: client) }
      let levels = try await thinkingLevels(client)
      let descriptors = try values.map { value -> AgentModelDescriptor in
        guard let provider = value["provider"]?.stringValue, let id = value["id"]?.stringValue
        else {
          throw PiRPCError.invalidRecord
        }
        let key = try PiModelKey(provider: provider, modelID: id)
        let resolved = key == selected
        let contextWindow = value["contextWindow"]?.integerValue.flatMap { $0 > 0 ? $0 : nil }
        let inputModalities = try modalities(value["input"])
        return try AgentModelDescriptor(
          id: key.encoded(),
          displayName: provider + " / " + (value["name"]?.stringValue ?? id),
          supportedReasoningEfforts: resolved ? levels : [],
          reasoningCapabilitiesAvailable: resolved,
          isDefaultModel: provider == current?["provider"]?.stringValue
            && id == current?["id"]?.stringValue,
          contextWindowTokens: contextWindow, inputModalities: inputModalities)
      }
      guard Set(descriptors.map(\.id)).count == descriptors.count else {
        throw PiRPCError.invalidRecord
      }
      await client.shutdown()
      return descriptors
    } catch {
      await client.shutdown()
      throw error
    }
  }

  func selectModel(_ rawValue: String, client: PiRPCClient) async throws {
    let key = try PiModelKey(rawValue: rawValue)
    let result = try await client.request(
      "set_model",
      fields: [
        "provider": .string(key.provider), "modelId": .string(key.modelID),
      ])
    guard result.data?["provider"]?.stringValue == key.provider,
      result.data?["id"]?.stringValue == key.modelID
    else { throw AgentRuntimeError.modelUnavailable(rawValue) }
  }

  func selectEffort(_ effort: String, client: PiRPCClient) async throws {
    guard try await thinkingLevels(client).contains(effort) else {
      throw AgentRuntimeError.invalidRequest("pi.effort")
    }
    _ = try await client.request("set_thinking_level", fields: ["level": .string(effort)])
    let state = try await client.request("get_state")
    guard state.data?["thinkingLevel"]?.stringValue == effort else {
      throw AgentRuntimeError.invalidRequest("pi.effort")
    }
  }

  private func thinkingLevels(_ client: PiRPCClient) async throws -> [String] {
    let response = try await client.request("get_available_thinking_levels")
    guard let values = response.data?["levels"]?.arrayValue, values.count <= 64 else {
      throw PiRPCError.invalidRecord
    }
    let levels = values.compactMap(\.stringValue)
    guard levels.count == values.count, Set(levels).count == levels.count,
      levels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 })
    else { throw PiRPCError.invalidRecord }
    return levels
  }

  private func modalities(_ value: PiJSONValue?) throws -> [AgentInputModality]? {
    guard let value else { return nil }
    guard let rawValues = value.arrayValue, rawValues.count <= 2 else {
      throw PiRPCError.invalidRecord
    }
    let strings = rawValues.compactMap(\.stringValue)
    guard strings.count == rawValues.count, Set(strings).count == strings.count else {
      throw PiRPCError.invalidRecord
    }
    let parsed = strings.compactMap(AgentInputModality.init(rawValue:))
    guard parsed.count == strings.count else { return nil }
    return parsed
  }
}

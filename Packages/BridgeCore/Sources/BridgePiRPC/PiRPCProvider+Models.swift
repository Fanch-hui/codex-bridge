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
      let keys = try Self.modelKeys(values)
      let requestedID: String?
      if let selectedModelID {
        requestedID = selectedModelID
      } else if let provider = current?["provider"]?.stringValue,
        let id = current?["id"]?.stringValue
      {
        requestedID = try PiModelKey(provider: provider, modelID: id).encoded()
      } else {
        requestedID = nil
      }
      let selected = try requestedID.flatMap { try Self.resolveModel($0, keys: keys) }
      if let selected {
        try await selectModel(try selected.encoded(), client: client, values: values)
      }
      let levels = selected == nil ? [] : try await thinkingLevels(client)
      let descriptors = try zip(values, keys).map { value, key -> AgentModelDescriptor in
        let resolved = key == selected
        let contextWindow = value["contextWindow"]?.integerValue.flatMap { $0 > 0 ? $0 : nil }
        let inputModalities = try modalities(value["input"])
        return try AgentModelDescriptor(
          id: key.encoded(),
          displayName: key.provider + " / " + (value["name"]?.stringValue ?? key.modelID),
          compatibleModelIDs: Self.compatibleModelIDs(for: key, keys: keys),
          supportedReasoningEfforts: resolved ? levels : [],
          reasoningCapabilitiesAvailable: resolved,
          isDefaultModel: key.provider == current?["provider"]?.stringValue
            && key.modelID == current?["id"]?.stringValue,
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

  static func modelKeys(_ values: [PiJSONValue]) throws -> [PiModelKey] {
    try values.map { value in
      guard let provider = value["provider"]?.stringValue, let id = value["id"]?.stringValue else {
        throw PiRPCError.invalidRecord
      }
      return try PiModelKey(provider: provider, modelID: id)
    }
  }

  static func compatibleModelIDs(for key: PiModelKey, keys: [PiModelKey]) throws -> [String] {
    guard let alternate = key.azureCompatibilityKey, !keys.contains(alternate) else { return [] }
    return [try alternate.encoded()]
  }

  static func resolveModel(_ rawValue: String, keys: [PiModelKey]) throws -> PiModelKey? {
    let requested = try PiModelKey(rawValue: rawValue)
    if keys.contains(requested) { return requested }
    guard let alternate = requested.azureCompatibilityKey, keys.contains(alternate) else {
      return nil
    }
    return alternate
  }

  func selectModel(_ rawValue: String, client: PiRPCClient, values: [PiJSONValue]) async throws {
    guard let key = try Self.resolveModel(rawValue, keys: Self.modelKeys(values)) else {
      throw AgentRuntimeError.modelUnavailable(rawValue)
    }
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

import BridgeACP
import Foundation

package enum ServiceCodexGatewayCatalogError: Error, Equatable {
  case invalidOfficialCatalog
  case invalidLocalPromptCatalog
  case duplicateModelID(String)
}

enum ServiceCodexGatewayCatalog {
  static let slugPrefix = "bridge."
  // Codex requires an instruction template for every explicitly listed model.
  private static let codexBaseInstructions = String(
    decoding: PackageResources.CodexBaseInstructions_md, as: UTF8.self)

  static func slug(for gatewayModelID: String) -> String {
    slugPrefix + gatewayModelID
  }

  static func officialModelIDs(in official: Data) throws -> Set<String> {
    try parse(official).modelIDs
  }

  static func merge(
    official: Data, gatewayModels: [ServiceGatewayModel], localPromptCatalog: Data? = nil
  ) throws -> Data {
    let catalog = try parse(official)
    var fields = catalog.fields
    var entries = catalog.entries
    var modelIDs = catalog.modelIDs

    if let localPromptCatalog {
      let prompts = try parseLocalPrompts(localPromptCatalog)
      entries = try entries.map { try overlayPrompts($0, prompts: prompts) }
    }

    for model in gatewayModels {
      let modelID = slug(for: model.id)
      guard !model.id.isEmpty, modelIDs.insert(modelID).inserted else {
        throw ServiceCodexGatewayCatalogError.duplicateModelID(modelID)
      }
      entries.append(entry(for: model, slug: modelID))
    }

    fields["models"] = .array(entries)
    return try ACPJSONValue.object(fields).encodedData()
  }

  /// Local catalog for Codex Desktop takeover mode: only gateway models, under their raw IDs
  /// because requests go straight to the gateway's `/v1/responses`.
  static func takeover(gatewayModels: [ServiceGatewayModel]) throws -> Data {
    var modelIDs: Set<String> = []
    let entries = try gatewayModels.map { model in
      guard !model.id.isEmpty, modelIDs.insert(model.id).inserted else {
        throw ServiceCodexGatewayCatalogError.duplicateModelID(model.id)
      }
      return entry(for: model, slug: model.id)
    }
    return try ACPJSONValue.object(["models": .array(entries)]).encodedData()
  }

  static func validateLocalPromptCatalog(_ data: Data) throws {
    _ = try parseLocalPrompts(data)
  }

  private static func parseLocalPrompts(_ data: Data) throws -> [String: [String: ACPJSONValue]] {
    let decoded: ACPJSONValue
    do {
      decoded = try JSONDecoder().decode(ACPJSONValue.self, from: data)
    } catch {
      throw ServiceCodexGatewayCatalogError.invalidLocalPromptCatalog
    }
    guard let entries = decoded["models"]?.arrayValue else {
      throw ServiceCodexGatewayCatalogError.invalidLocalPromptCatalog
    }
    var prompts: [String: [String: ACPJSONValue]] = [:]
    for entry in entries {
      guard let fields = entry.objectValue,
        let modelID = fields["slug"]?.stringValue, !modelID.isEmpty,
        prompts[modelID] == nil
      else { throw ServiceCodexGatewayCatalogError.invalidLocalPromptCatalog }
      if let base = fields["base_instructions"], base != .null, base.stringValue == nil {
        throw ServiceCodexGatewayCatalogError.invalidLocalPromptCatalog
      }
      if let messages = fields["model_messages"], messages != .null {
        guard let values = messages.objectValue else {
          throw ServiceCodexGatewayCatalogError.invalidLocalPromptCatalog
        }
        if let template = values["instructions_template"], template != .null,
          template.stringValue == nil
        {
          throw ServiceCodexGatewayCatalogError.invalidLocalPromptCatalog
        }
      }
      prompts[modelID] = fields
    }
    return prompts
  }

  private static func overlayPrompts(
    _ entry: ACPJSONValue, prompts: [String: [String: ACPJSONValue]]
  ) throws -> ACPJSONValue {
    guard var official = entry.objectValue, let modelID = official["slug"]?.stringValue else {
      throw ServiceCodexGatewayCatalogError.invalidOfficialCatalog
    }
    guard let local = prompts[modelID] else { return entry }

    let base = local["base_instructions"]?.stringValue
    if let base { official["base_instructions"] = .string(base) }
    let localMessages = local["model_messages"]?.objectValue ?? [:]
    let legacyTemplate = base.flatMap { $0.isEmpty ? nil : $0 }
    let officialMessages = official["model_messages"]?.objectValue
    let needsLegacyTemplate =
      legacyTemplate != nil && localMessages["instructions_template"] == nil
      && officialMessages?["instructions_template"] != nil
    if !localMessages.isEmpty || needsLegacyTemplate {
      var messages = officialMessages ?? [:]
      messages.merge(localMessages) { _, local in local }
      if needsLegacyTemplate, let legacyTemplate {
        messages["instructions_template"] = .string(legacyTemplate)
      }
      official["model_messages"] = .object(messages)
    }
    return .object(official)
  }

  private static func parse(_ data: Data) throws -> (
    fields: [String: ACPJSONValue], entries: [ACPJSONValue], modelIDs: Set<String>
  ) {
    guard let fields = try JSONDecoder().decode(ACPJSONValue.self, from: data).objectValue,
      let entries = fields["models"]?.arrayValue
    else { throw ServiceCodexGatewayCatalogError.invalidOfficialCatalog }
    var modelIDs: Set<String> = []
    for entry in entries {
      guard let modelID = entry["slug"]?.stringValue, !modelID.isEmpty else {
        throw ServiceCodexGatewayCatalogError.invalidOfficialCatalog
      }
      guard modelIDs.insert(modelID).inserted else {
        throw ServiceCodexGatewayCatalogError.duplicateModelID(modelID)
      }
    }
    return (fields, entries, modelIDs)
  }

  private static let providerAbbreviations = ["agy-cli": "AGY"]

  /// Uses a known abbreviation, otherwise drops a trailing qualifier such as "Name (local CLI)".
  static func shortProviderName(_ name: String, providerID: String) -> String {
    if let abbreviation = providerAbbreviations[providerID] { return abbreviation }
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else { return trimmed }
    let short = trimmed[..<open].trimmingCharacters(in: .whitespaces)
    return short.isEmpty ? trimmed : short
  }

  private static func entry(for model: ServiceGatewayModel, slug: String) -> ACPJSONValue {
    let provider = shortProviderName(
      model.providerName.flatMap { $0.isEmpty ? nil : $0 } ?? model.providerID,
      providerID: model.providerID)
    let efforts = model.reasoningEfforts ?? []
    let defaultEffort = efforts.contains("medium") ? "medium" : efforts.first
    var fields: [String: ACPJSONValue] = [
      "slug": .string(slug),
      // The picker truncates long names, so the model comes first and the provider stays short.
      "display_name": .string("\(model.name) · \(provider)"),
      "description": .string("通过 Codex Bridge 使用 \(provider) 模型"),
      "base_instructions": .string(codexBaseInstructions),
      "default_reasoning_level": defaultEffort.map(ACPJSONValue.string) ?? .null,
      "supported_reasoning_levels": .array(
        efforts.map { effort in
          .object(["effort": .string(effort), "description": .string(effort)])
        }),
      "shell_type": .string("shell_command"),
      "visibility": .string("list"),
      "supported_in_api": .bool(true),
      "priority": .integer(Int64(Int32.max)),
      "upgrade": .null,
      "availability_nux": .null,
      "support_verbosity": .bool(false),
      "default_verbosity": .null,
      "apply_patch_tool_type": .null,
      "truncation_policy": .object(["mode": .string("tokens"), "limit": .integer(10_000)]),
      "experimental_supported_tools": .array([]),
      "input_modalities": .array(
        model.supportsImages == true ? [.string("text"), .string("image")] : [.string("text")]),
      "supports_reasoning_summary_parameter": .bool(false),
      // Without client-side tool search, Codex inlines every connected app's tools (~2 MB per
      // request); the gateway relays `tool_search` calls so those tools load on demand.
      "supports_search_tool": .bool(true),
      // The Chat adapter supports client-executed tools, while hosted tools stay on official models.
      "use_responses_lite": .bool(true),
      "tool_mode": .string("direct"),
      "service_tiers": .array([]),
      "additional_speed_tiers": .array([]),
      "default_service_tier": .null,
    ]
    if let context = model.knownContextWindow {
      fields["context_window"] = .integer(Int64(context))
      fields["max_context_window"] = .integer(Int64(context))
      if let output = model.defaultMaxTokens, output > 0 {
        // Leave room for one response, but never more than half the window: some providers
        // report a max output as large as the context, which would compact on every turn.
        fields["auto_compact_token_limit"] = .integer(Int64(context - min(output, context / 2)))
      }
    }
    return .object(fields)
  }
}

public struct MCPAgentModelSummary: Codable, Equatable, Sendable {
  public let modelID: String
  public let displayName: String
  public let reasoningEfforts: [String]
  public let defaultReasoningEffort: String?
  public let reasoningCapabilitiesAvailable: Bool
  public let isDefault: Bool?

  public init(
    modelID: String,
    displayName: String,
    reasoningEfforts: [String],
    defaultReasoningEffort: String?,
    reasoningCapabilitiesAvailable: Bool,
    isDefault: Bool?
  ) {
    self.modelID = modelID
    self.displayName = displayName
    self.reasoningEfforts = reasoningEfforts
    self.defaultReasoningEffort = defaultReasoningEffort
    self.reasoningCapabilitiesAvailable = reasoningCapabilitiesAvailable
    self.isDefault = isDefault
  }

  private enum CodingKeys: String, CodingKey {
    case modelID = "model_id"
    case displayName = "display_name"
    case reasoningEfforts = "reasoning_efforts"
    case defaultReasoningEffort = "default_reasoning_effort"
    case reasoningCapabilitiesAvailable = "reasoning_capabilities_available"
    case isDefault = "is_default"
  }
}

public struct MCPAgentModelList: Codable, Equatable, Sendable {
  public let installationID: String
  public let models: [MCPAgentModelSummary]

  public init(installationID: String, models: [MCPAgentModelSummary]) {
    self.installationID = installationID
    self.models = models
  }

  private enum CodingKeys: String, CodingKey {
    case installationID = "installation_id"
    case models
  }
}

struct ListAgentModelsOutput: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let installationID: String
  let models: [MCPAgentModelSummary]

  init(_ list: MCPAgentModelList) {
    schemaVersion = 1
    installationID = list.installationID
    models = list.models
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case installationID = "installation_id"
    case models
  }
}

import Foundation

public struct ServiceAgentModelListItem: Codable, Equatable, Sendable {
  public let modelID: String
  public let compatibleModelIDs: [String]
  public let displayName: String
  public let supportedReasoningEfforts: [String]
  public let defaultReasoningEffort: String?
  public let reasoningCapabilitiesAvailable: Bool
  public let isDefaultModel: Bool?

  public init(
    modelID: String,
    displayName: String,
    compatibleModelIDs: [String] = [],
    supportedReasoningEfforts: [String] = [],
    defaultReasoningEffort: String? = nil,
    reasoningCapabilitiesAvailable: Bool = true,
    isDefaultModel: Bool? = nil
  ) {
    self.modelID = modelID
    self.compatibleModelIDs = compatibleModelIDs
    self.displayName = displayName
    self.supportedReasoningEfforts = supportedReasoningEfforts
    self.defaultReasoningEffort = defaultReasoningEffort
    self.reasoningCapabilitiesAvailable = reasoningCapabilitiesAvailable
    self.isDefaultModel = isDefaultModel
  }
  private enum CodingKeys: String, CodingKey {
    case modelID, displayName, compatibleModelIDs, supportedReasoningEfforts
    case defaultReasoningEffort, reasoningCapabilitiesAvailable, isDefaultModel
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      modelID: try values.decode(String.self, forKey: .modelID),
      displayName: try values.decode(String.self, forKey: .displayName),
      compatibleModelIDs: try values.decodeIfPresent([String].self, forKey: .compatibleModelIDs)
        ?? [],
      supportedReasoningEfforts: try values.decodeIfPresent(
        [String].self, forKey: .supportedReasoningEfforts) ?? [],
      defaultReasoningEffort: try values.decodeIfPresent(
        String.self, forKey: .defaultReasoningEffort),
      reasoningCapabilitiesAvailable: try values.decodeIfPresent(
        Bool.self, forKey: .reasoningCapabilitiesAvailable) ?? true,
      isDefaultModel: try values.decodeIfPresent(Bool.self, forKey: .isDefaultModel))
  }
}

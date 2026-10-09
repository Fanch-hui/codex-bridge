import BridgeCodexRPC
import BridgeMCP
import BridgeSecurity
import Foundation

enum ServiceCodexCatalogModelProjection {
  static func model(_ source: CodexModel, index: Int) throws -> MCPModelSummary {
    let path = "data[\(index)]"
    try validateIdentifier(source.id, maximum: 256, field: "\(path).id")
    let displayName = OutboundContentSecurity.redacted(
      source.displayName,
      maximumUTF8Bytes: 1_024
    )
    guard !displayName.isEmpty else {
      throw invalid("\(path).displayName", reason: "empty_display_name")
    }
    let efforts = source.supportedReasoningEfforts.map(\.reasoningEffort)
    guard !efforts.isEmpty, Set(efforts).count == efforts.count else {
      throw invalid("\(path).supportedReasoningEfforts", reason: "empty_or_duplicate_efforts")
    }
    for effort in efforts {
      try validateIdentifier(effort, maximum: 64, field: "\(path).supportedReasoningEfforts")
    }
    var tiers: [String] = []
    for tier in source.serviceTiers ?? [] {
      try validateIdentifier(tier.id, maximum: 64, field: "\(path).serviceTiers.id")
      guard !tiers.contains(tier.id) else {
        throw invalid("\(path).serviceTiers.id", reason: "duplicate_identifier")
      }
      tiers.append(tier.id)
    }
    var speedTiers: [String] = []
    for tier in source.additionalSpeedTiers ?? [] {
      try validateIdentifier(tier, maximum: 64, field: "\(path).additionalSpeedTiers")
      guard !speedTiers.contains(tier) else {
        throw invalid("\(path).additionalSpeedTiers", reason: "duplicate_identifier")
      }
      speedTiers.append(tier)
    }
    let defaultEffort: String?
    if source.defaultReasoningEffort.isEmpty {
      defaultEffort = nil
    } else {
      try validateIdentifier(
        source.defaultReasoningEffort, maximum: 64, field: "\(path).defaultReasoningEffort")
      guard efforts.contains(source.defaultReasoningEffort) else {
        throw invalid("\(path).defaultReasoningEffort", reason: "default_effort_not_supported")
      }
      defaultEffort = source.defaultReasoningEffort
    }
    return MCPModelSummary(
      modelID: source.id,
      displayName: displayName,
      isDefault: source.isDefault,
      reasoningEfforts: efforts,
      defaultReasoningEffort: defaultEffort,
      serviceTiers: tiers,
      additionalSpeedTiers: speedTiers
    )
  }

  private static func validateIdentifier(_ value: String, maximum: Int, field: String) throws {
    guard !value.isEmpty,
      value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      value.utf8.count <= maximum,
      !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil,
      OutboundContentSecurity.isSafe(value)
    else {
      throw invalid(field, reason: "invalid_identifier")
    }
  }

  private static func invalid(_ field: String, reason: String) -> BridgeMCPQueryError {
    .codexAppServerUnavailable(
      "Codex model/list catalog validation failed (\(reason) at \(field)).")
  }
}

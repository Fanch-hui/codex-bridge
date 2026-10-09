import BridgeMCP
import Foundation

enum ServiceCodexModelCatalogDiagnostics {
  static func decodingFailure(_ error: DecodingError) -> BridgeMCPQueryError {
    let reason: String
    let path: [any CodingKey]
    switch error {
    case .keyNotFound(let key, let context):
      reason = "missing_field"
      path = context.codingPath + [key]
    case .typeMismatch(_, let context):
      reason = "type_mismatch"
      path = context.codingPath
    case .valueNotFound(_, let context):
      reason = "null_value"
      path = context.codingPath
    case .dataCorrupted(let context):
      reason = "invalid_value"
      path = context.codingPath
    @unknown default:
      reason = "invalid_response"
      path = []
    }
    return .codexAppServerUnavailable(
      "Codex model/list response decoding failed (\(reason) at \(fieldPath(path))).")
  }

  private static func fieldPath(_ keys: [any CodingKey]) -> String {
    let fields: Set<String> = [
      "data", "nextCursor", "id", "model", "displayName", "description", "hidden",
      "supportedReasoningEfforts", "reasoningEffort", "defaultReasoningEffort", "isDefault",
      "upgrade", "upgradeInfo", "availabilityNux", "inputModalities", "supportsPersonality",
      "additionalSpeedTiers", "serviceTiers", "name", "defaultServiceTier",
    ]
    var path = ""
    for key in keys.prefix(12) {
      if let index = key.intValue {
        path += "[\(index)]"
      } else {
        // Only protocol field names are diagnostic data; dictionary keys can contain user values.
        let field = fields.contains(key.stringValue) ? key.stringValue : "field"
        path += path.isEmpty ? field : ".\(field)"
      }
    }
    return path.isEmpty ? "result" : path
  }
}

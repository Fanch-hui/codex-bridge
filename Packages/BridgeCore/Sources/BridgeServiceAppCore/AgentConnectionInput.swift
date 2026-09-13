import Foundation

public enum AgentConnectionInput {
  public static func baseURL(_ value: String?) -> String? {
    normalized(value)
  }

  public static func apiKey(_ value: String?) -> String? {
    normalized(value)
  }

  public static func isValid(
    providerRequiresConfiguration: Bool,
    hasExistingInstallation: Bool,
    baseURL: String?,
    apiKey: String?
  ) -> Bool {
    guard providerRequiresConfiguration else { return true }
    let hasBaseURL = Self.baseURL(baseURL) != nil
    let hasAPIKey = Self.apiKey(apiKey) != nil
    if !hasExistingInstallation { return hasBaseURL && hasAPIKey }
    return hasBaseURL == hasAPIKey
  }

  private static func normalized(_ value: String?) -> String? {
    guard let value, !value.contains("\0"), value.utf8.count <= 16 * 1_024 else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

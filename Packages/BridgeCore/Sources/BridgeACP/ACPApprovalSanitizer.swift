import Foundation

package enum ACPApprovalSanitizer {
  package static func safeText(_ value: String) -> String? {
    guard !value.isEmpty, value.utf8.count <= 8 * 1_024,
      !value.contains("\0"), value.rangeOfCharacter(from: .controlCharacters) == nil,
      !containsSensitiveMarker(value.lowercased())
    else { return nil }
    return value
  }

  package static func safeCommand(_ value: String?) -> String? {
    guard let value else { return nil }
    return safeText(value)
  }

  package static func safeNetworkTarget(_ value: String?) -> String? {
    guard let value, value.utf8.count <= 4 * 1_024,
      !value.contains("\0"), value.rangeOfCharacter(from: .controlCharacters) == nil,
      let url = URLComponents(string: value),
      let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
      url.host != nil,
      !containsSensitiveMarker(value.lowercased())
    else { return nil }
    var sanitized = url
    sanitized.user = nil
    sanitized.password = nil
    sanitized.query = nil
    sanitized.fragment = nil
    guard let result = sanitized.string, result.utf8.count <= 4 * 1_024 else { return nil }
    return result
  }

  package static func containsSensitiveMarker(_ value: String) -> Bool {
    [
      "token", "secret", "password", "passwd", "api_key", "apikey", "authorization",
      "cookie", "private_key", ".env", ".ssh",
    ].contains { value.contains($0) }
  }
}

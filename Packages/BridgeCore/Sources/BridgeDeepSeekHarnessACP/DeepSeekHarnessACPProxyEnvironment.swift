import Foundation

enum DeepSeekHarnessACPProxyEnvironment {
  static let keys = [
    "http_proxy", "https_proxy", "all_proxy", "no_proxy",
    "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
  ]

  static func apply(to environment: inout [String: String], from source: [String: String]) {
    for key in keys {
      guard let value = source[key], !value.isEmpty,
        value.rangeOfCharacter(from: .controlCharacters) == nil
      else { continue }
      environment[key] = value
    }
  }
}

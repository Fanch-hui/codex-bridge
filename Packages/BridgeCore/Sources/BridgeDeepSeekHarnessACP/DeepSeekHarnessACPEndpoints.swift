import BridgeAgentCore
import Foundation

struct DeepSeekHarnessACPEndpoints: Equatable, Sendable {
  let inferenceProtocol: DeepSeekHarnessConnectionProtocol
  let inferenceBaseURL: String
  let catalogURL: URL?
  let searchBaseURL: String?

  static func resolve(environment: [String: String], usesMessagesProvider: Bool) throws -> Self {
    let original = environment["DEEPSEEK_BASE_URL"] ?? "https://api.deepseek.com"
    let base = try validatedURL(original)
    let explicit = environment["BRIDGE_DSH_PROTOCOL"].flatMap(
      { DeepSeekHarnessConnectionProtocol(rawValue: $0) })
    let official = base.host?.lowercased() == "api.deepseek.com"
    let api = explicit ?? (official ? .deepSeekMessages : .openAICompletions)
    let inference: String
    if usesMessagesProvider && api == .deepSeekMessages && official
      && (base.path.isEmpty || base.path == "/" || base.path == "/v1" || base.path == "/v1/")
    {
      inference = "https://api.deepseek.com/anthropic"
    } else {
      inference = original
    }
    let catalogBase: String?
    if let configured = environment["BRIDGE_DSH_CATALOG_BASE_URL"], !configured.isEmpty {
      catalogBase = configured
    } else if official {
      catalogBase = "https://api.deepseek.com"
    } else if !usesMessagesProvider || api == .openAICompletions {
      catalogBase = original
    } else {
      catalogBase = nil
    }
    let catalogURL = try catalogBase.map { try validatedURL($0).appendingPathComponent("models") }
    let search =
      environment["DEEPSEEK_SEARCH_BASE_URL"]
      ?? (usesMessagesProvider ? nil : environment["DEEPSEEK_BASE_URL"])
    if let search { _ = try validatedURL(search) }
    return Self(
      inferenceProtocol: api, inferenceBaseURL: inference,
      catalogURL: catalogURL, searchBaseURL: search)
  }

  static func validatedURL(_ value: String) throws -> URL {
    guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
      url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
    else { throw AgentRuntimeError.invalidRequest("deepseek.base_url") }
    return url
  }
}

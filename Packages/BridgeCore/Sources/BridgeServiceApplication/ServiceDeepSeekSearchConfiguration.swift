import BridgeServiceCore
import Foundation

public struct ServiceDeepSeekSearchConfiguration: Sendable {
  let settings: ServiceSettings
  public init(settings: ServiceSettings) { self.settings = settings }
  public func baseURL() async throws -> String? {
    try await settings.string(for: .deepSeekHarnessSearchBaseURL)
  }
  public func save(baseURL: String?) async throws -> String? {
    let value = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = value?.isEmpty == false ? value : nil
    if let normalized {
      guard let url = URL(string: normalized),
        ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
        url.host?.isEmpty == false, url.user == nil, url.password == nil,
        url.query == nil, url.fragment == nil
      else { throw ServiceStoreError.invalidArgument("deepseek.search.baseURL") }
    }
    let result = normalized.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
    try await settings.set(result, for: .deepSeekHarnessSearchBaseURL)
    return result
  }
  public func applying(to environment: [String: String]) async throws -> [String: String] {
    var result = environment
    if let url = try await baseURL() { result["DEEPSEEK_SEARCH_BASE_URL"] = url }
    return result
  }
}

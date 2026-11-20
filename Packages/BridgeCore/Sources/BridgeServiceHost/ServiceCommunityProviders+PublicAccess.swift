import BridgeACP
import BridgeProviderRuntime
import Foundation

extension ServiceCommunityProviders {
  private static let publicProvider = "opencode-zen-free"

  static func supportsAutomaticPublicAccess(_ plugin: Plugin) -> Bool {
    plugin.package == "@magpie-community/opencode-zen-free-auth"
      && plugin.version == "0.1.28"
      && plugin.providers == [publicProvider]
  }

  func connectAutomaticPublicAccess(_ plugin: Plugin, using client: ProviderHostClient) async throws
  {
    guard Self.supportsAutomaticPublicAccess(plugin), plugin.enabled else { return }
    let params: ACPJSONValue = .object(["provider": .string(Self.publicProvider)])
    let summary = try await request(client, method: "providerSummary", params: params)
    guard let accounts = summary["accounts"]?.arrayValue else {
      throw ServiceCommunityProviderError.invalidRequest
    }
    if !accounts.isEmpty { return }
    let methods = try await request(client, method: "authMethods", params: params)
    guard let choices = methods["methods"]?.arrayValue, choices.count == 1,
      choices[0]["type"]?.stringValue == "api", choices[0]["keyless"]?.boolValue == true
    else {
      throw ServiceCommunityProviderError.unavailableAuthentication
    }
    let result = try await request(
      client, method: "apiKey",
      params: .object([
        "provider": .string(Self.publicProvider), "method": .integer(0),
        "inputs": .object([:]),
      ]))
    guard result["ok"]?.boolValue == true else {
      throw ServiceCommunityProviderError.incompatible(
        result["error"]?.stringValue ?? "插件没有确认公开访问连接。")
    }
  }
}

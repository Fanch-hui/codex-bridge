import BridgeAgentCore
import Foundation

extension ServiceSettings {
  public func deepSeekHarnessDesktopNamespaces() async throws -> [String: String] {
    guard let value = try await string(for: .deepSeekHarnessDesktopNamespaces) else { return [:] }
    guard let result = try? JSONDecoder().decode([String: String].self, from: Data(value.utf8))
    else {
      throw ServiceStoreError.corruptRecord
    }
    try Self.validateDesktopNamespaces(result)
    return result
  }

  public func setDeepSeekHarnessDesktopNamespaces(_ namespaces: [String: String]) async throws {
    try Self.validateDesktopNamespaces(namespaces)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(namespaces)
    try await set(String(decoding: data, as: UTF8.self), for: .deepSeekHarnessDesktopNamespaces)
  }

  public func deepSeekHarnessDesktopNamespace(for installationID: AgentInstallationID) async throws
    -> AgentInstallationID
  {
    .init(
      rawValue: try await deepSeekHarnessDesktopNamespaces()[installationID.rawValue]
        ?? installationID.rawValue)
  }

  private static func validateDesktopNamespaces(_ namespaces: [String: String]) throws {
    for (installationID, namespaceID) in namespaces {
      try ServiceValidation.identifier(
        installationID, field: "desktop.installation", maximumBytes: 256)
      try ServiceValidation.identifier(namespaceID, field: "desktop.namespace", maximumBytes: 256)
      guard installationID != namespaceID, namespaces[namespaceID] == nil else {
        throw ServiceStoreError.invalidArgument("desktop.namespace")
      }
    }
  }
}

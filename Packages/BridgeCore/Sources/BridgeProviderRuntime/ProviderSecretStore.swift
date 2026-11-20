import BridgeACP
import BridgeSecurity
import Foundation

/// One service-owned store per plugin installation; provider account changes commit together.
public actor ProviderSecretStore {
  private let store: any SecretStore
  private let installationID: UUID
  private let providers: Set<String>

  public init(store: any SecretStore, installationID: UUID, providers: Set<String>) throws {
    guard !providers.isEmpty, providers.allSatisfy(Self.validProvider) else {
      throw ProviderRuntimeError.invalidMessage
    }
    self.store = store
    self.installationID = installationID
    self.providers = providers
  }

  public func handle(_ params: ACPJSONValue) throws -> ACPJSONValue {
    guard let provider = params["provider"]?.stringValue, providers.contains(provider),
      let operation = params["operation"]?.stringValue
    else { throw ProviderRuntimeError.invalidMessage }
    let reference = try SecretReference(
      validating: "provider.\(installationID.uuidString.lowercased()).\(provider)")
    var accounts = try read(reference)
    switch operation {
    case "list":
      return .object(["keys": .array(accounts.keys.sorted().map(ACPJSONValue.string))])
    case "get":
      let key = try accountKey(params["key"], provider: provider)
      return .object(["value": accounts[key] ?? .null])
    case "commit":
      guard let changes = params["changes"]?.arrayValue, !changes.isEmpty,
        changes.count <= 128
      else { throw ProviderRuntimeError.invalidMessage }
      for change in changes {
        let key = try accountKey(change["key"], provider: provider)
        if let value = change["value"], value != .null {
          guard value.objectValue != nil else { throw ProviderRuntimeError.invalidMessage }
          accounts[key] = value
        } else {
          accounts.removeValue(forKey: key)
        }
      }
      // An empty record is also a single atomic write, including on first-time sign-out.
      try store.store(try ACPJSONValue.object(accounts).encodedData(), for: reference)
      return .object([:])
    default:
      throw ProviderRuntimeError.invalidMessage
    }
  }

  private func read(_ reference: SecretReference) throws -> [String: ACPJSONValue] {
    do {
      let value = try JSONDecoder().decode(ACPJSONValue.self, from: store.load(reference))
      guard let accounts = value.objectValue else { throw SecretStoreError.invalidStoredValue }
      return accounts
    } catch SecretStoreError.notFound {
      return [:]
    }
  }

  private func accountKey(_ value: ACPJSONValue?, provider: String) throws -> String {
    guard let key = value?.stringValue, key.utf8.count <= 256,
      key == provider || (key.hasPrefix(provider + "#") && key.count > provider.count + 1),
      !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw ProviderRuntimeError.invalidMessage }
    return key
  }

  private static func validProvider(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 64
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || $0 == 45 || $0 == 95 || $0 == 46
      }
  }
}

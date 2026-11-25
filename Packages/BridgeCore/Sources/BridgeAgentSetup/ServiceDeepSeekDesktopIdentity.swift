import BridgeSecurity
import Crypto
import Foundation

actor ServiceDeepSeekDesktopIdentity {
  private let store: any SecretStore
  private let reference: SecretReference

  init(store: any SecretStore, dataRoot: URL) {
    self.store = store
    let scope = SHA256.hash(data: Data(dataRoot.standardizedFileURL.path.utf8))
      .map { String(format: "%02x", $0) }.joined()
    reference = SecretReference(rawValue: "dsh-desktop-identity." + scope)
  }

  func privateKey() throws -> Data {
    do {
      let bytes = try store.load(reference)
      _ = try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
      return bytes
    } catch SecretStoreError.notFound {
      let key = Curve25519.Signing.PrivateKey()
      try store.store(key.rawRepresentation, for: reference)
      return key.rawRepresentation
    }
  }
}

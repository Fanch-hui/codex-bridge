#if canImport(Security)
  import Foundation

  protocol SecretStoreLock: Sendable {
    func withLock<T>(_ body: () throws -> T) throws -> T
  }

  /// Keeps Bridge credentials in one Keychain item. Legacy items are migrated only when used.
  final class KeychainVaultSecretStore: SecretStore, Sendable {
    private static let vaultReference = SecretReference(rawValue: "vault.v1")
    private static let maximumVaultBytes = 64 * 1024 * 1024

    private let legacy: any SecretStore
    private let legacyCleanup: any SecretStore
    private let vault: any SecretStore
    private let lock: any SecretStoreLock

    init() {
      legacy = KeychainSecretStore(allowsUserInteraction: true)
      legacyCleanup = KeychainSecretStore(allowsUserInteraction: false)
      vault = KeychainSecretStore(
        service: "\(KeychainSecretStore.defaultService).vault",
        allowsUserInteraction: true,
        maximumStoredBytes: Self.maximumVaultBytes
      )
      lock = KeychainVaultLock()
    }

    init(
      legacy: any SecretStore, legacyCleanup: (any SecretStore)? = nil,
      vault: any SecretStore, lock: any SecretStoreLock
    ) {
      self.legacy = legacy
      self.legacyCleanup = legacyCleanup ?? legacy
      self.vault = vault
      self.lock = lock
    }

    func store(_ secret: Data, for reference: SecretReference) throws {
      guard !secret.isEmpty, secret.count <= KeychainSecretStore.maximumSecretBytes else {
        throw SecretStoreError.invalidSecret
      }
      try lock.withLock {
        var contents = try readVault()
        if let existing = contents.entries[reference.rawValue], !existing.legacyCleanupPending {
          contents.entries[reference.rawValue] = Entry(value: secret, legacyCleanupPending: false)
          try save(contents)
          return
        }
        contents.entries[reference.rawValue] = Entry(value: secret, legacyCleanupPending: true)
        try save(contents)
        try finishLegacyCleanup(reference, contents: &contents)
      }
    }

    func load(_ reference: SecretReference) throws -> Data {
      try lock.withLock {
        var contents = try readVault()
        if let entry = contents.entries[reference.rawValue] {
          if entry.legacyCleanupPending {
            try cleanupForLoad(reference, contents: &contents)
          }
          guard let value = entry.value else { throw SecretStoreError.notFound }
          return value
        }

        let value = try legacy.load(reference)
        guard !value.isEmpty, value.count <= KeychainSecretStore.maximumSecretBytes else {
          throw SecretStoreError.invalidStoredValue
        }
        contents.entries[reference.rawValue] = Entry(value: value, legacyCleanupPending: true)
        try save(contents)
        try cleanupForLoad(reference, contents: &contents)
        return value
      }
    }

    func remove(_ reference: SecretReference) throws {
      try lock.withLock {
        var contents = try readVault()
        if let existing = contents.entries[reference.rawValue], !existing.legacyCleanupPending {
          contents.entries.removeValue(forKey: reference.rawValue)
          try save(contents)
          return
        }
        contents.entries[reference.rawValue] = Entry(value: nil, legacyCleanupPending: true)
        try save(contents)
        try finishLegacyCleanup(reference, contents: &contents)
      }
    }

    private func cleanupForLoad(_ reference: SecretReference, contents: inout Vault) throws {
      do {
        try finishLegacyCleanup(reference, contents: &contents, using: legacyCleanup)
      } catch SecretStoreError.accessDenied {
        // The persisted marker keeps cleanup pending until noninteractive access succeeds.
      }
    }

    private func finishLegacyCleanup(
      _ reference: SecretReference, contents: inout Vault, using store: (any SecretStore)? = nil
    ) throws {
      try (store ?? legacy).remove(reference)
      if let value = contents.entries[reference.rawValue]?.value {
        contents.entries[reference.rawValue] = Entry(value: value, legacyCleanupPending: false)
      } else {
        contents.entries.removeValue(forKey: reference.rawValue)
      }
      try save(contents)
    }

    private func readVault() throws -> Vault {
      let data: Data
      do {
        data = try vault.load(Self.vaultReference)
      } catch SecretStoreError.notFound {
        return Vault()
      }
      guard data.count <= Self.maximumVaultBytes,
        let contents = try? PropertyListDecoder().decode(Vault.self, from: data),
        contents.formatVersion == 1,
        contents.entries.allSatisfy({ key, entry in
          (try? SecretReference(validating: key)) != nil
            && (entry.value.map {
              !$0.isEmpty && $0.count <= KeychainSecretStore.maximumSecretBytes
            }
              ?? entry.legacyCleanupPending)
        })
      else {
        throw SecretStoreError.invalidStoredValue
      }
      return contents
    }

    private func save(_ contents: Vault) throws {
      let encoder = PropertyListEncoder()
      encoder.outputFormat = .binary
      let data = try encoder.encode(contents)
      guard data.count <= Self.maximumVaultBytes else { throw SecretStoreError.invalidSecret }
      try vault.store(data, for: Self.vaultReference)
    }

    private struct Vault: Codable {
      var formatVersion = 1
      var entries: [String: Entry] = [:]
    }

    private struct Entry: Codable {
      var value: Data?
      var legacyCleanupPending: Bool
    }
  }
#endif

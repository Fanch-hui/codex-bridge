public enum SecretStoreFactory {
  /// Platform default secret backend: Keychain on macOS, Credential Manager
  /// on Windows, and Secret Service on Linux.
  public static func defaultStore() -> any SecretStore {
    #if canImport(Security)
      return KeychainSecretStore(allowsUserInteraction: false)
    #elseif os(Windows)
      return WindowsCredentialStore()
    #elseif os(Linux)
      return LinuxSecretServiceStore()
    #else
      fatalError("No SecretStore backend for this platform")
    #endif
  }
}

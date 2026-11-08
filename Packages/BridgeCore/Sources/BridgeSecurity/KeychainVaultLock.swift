#if canImport(Security)
  import Darwin
  import Foundation

  /// Serializes vault read-modify-write operations across service processes for this user.
  struct KeychainVaultLock: SecretStoreLock {
    private static let processLock = NSLock()

    func withLock<T>(_ body: () throws -> T) throws -> T {
      Self.processLock.lock()
      defer { Self.processLock.unlock() }

      let directory = try openPrivateDirectory()
      defer { close(directory) }
      let descriptor = openat(
        directory, ".keychain-vault.lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard descriptor >= 0 else { throw SecretStoreError.accessDenied }
      defer { close(descriptor) }
      var info = stat()
      guard fstat(descriptor, &info) == 0,
        info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
        info.st_mode & 0o077 == 0, info.st_nlink == 1
      else { throw SecretStoreError.accessDenied }

      while flock(descriptor, LOCK_EX) != 0 {
        guard errno == EINTR else { throw SecretStoreError.accessDenied }
      }
      return try body()
    }

    private func openPrivateDirectory() throws -> Int32 {
      let fileManager = FileManager.default
      let parent =
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
          "Library/Application Support")
      let root = parent.appendingPathComponent("CodexBridgeService", isDirectory: true)
      do {
        try fileManager.createDirectory(
          at: root, withIntermediateDirectories: true,
          attributes: [.posixPermissions: NSNumber(value: 0o700)])
      } catch {
        throw SecretStoreError.accessDenied
      }
      let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      guard descriptor >= 0 else { throw SecretStoreError.accessDenied }
      var info = stat()
      guard fstat(descriptor, &info) == 0,
        info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
        info.st_mode & 0o077 == 0
      else {
        close(descriptor)
        throw SecretStoreError.accessDenied
      }
      return descriptor
    }
  }
#endif

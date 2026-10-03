#if !os(Windows)
  import Foundation
  #if canImport(Darwin)
    import Darwin
  #else
    import Glibc
  #endif

  enum GitPatchStorePersistencePOSIX {
    static func openPrivateDirectory(_ url: URL) throws -> Int32 {
      guard url.isFileURL, url.path.hasPrefix("/") else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      do {
        try FileManager.default.createDirectory(
          at: url,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
      } catch {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      var metadata = stat()
      guard lstat(url.path, &metadata) == 0, metadata.st_uid == getuid(),
        metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o777 == 0o700
      else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard descriptor >= 0 else { throw GitEvidenceError.patchStoreCapacityExceeded }
      return descriptor
    }

    static func openLockFile(in descriptor: Int32) throws -> Int32 {
      let lock = openat(
        descriptor,
        GitPatchStorePersistence.lockFileName,
        O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
        S_IRUSR | S_IWUSR
      )
      guard lock >= 0 else { throw GitEvidenceError.patchStoreCapacityExceeded }
      var metadata = stat()
      guard fstat(lock, &metadata) == 0, metadata.st_uid == getuid(),
        metadata.st_mode & S_IFMT == S_IFREG,
        fchmod(lock, S_IRUSR | S_IWUSR) == 0
      else {
        close(lock)
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      return lock
    }

    static func loadDocuments(
      directory: URL,
      descriptor: Int32
    ) throws -> [String: GitPatchStoreDocument] {
      try recoverStagedDocuments(directory: directory, descriptor: descriptor)
      let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
        $0 != GitPatchStorePersistence.lockFileName
      }
      guard names.count <= 1_024, names.allSatisfy(GitPatchStorePersistence.validIdentifier) else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      var result: [String: GitPatchStoreDocument] = [:]
      for name in names {
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw GitEvidenceError.patchStoreCapacityExceeded }
        defer { close(file) }
        var metadata = stat()
        guard fstat(file, &metadata) == 0, metadata.st_uid == getuid(),
          metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o777 == 0o600,
          metadata.st_size >= 0, let byteCount = Int(exactly: metadata.st_size)
        else { throw GitEvidenceError.patchStoreCapacityExceeded }
        result[name] = GitPatchStoreDocument(
          byteCount: byteCount,
          lastAccess: Date(
            timeIntervalSince1970: TimeInterval(metadata.modificationTime.tv_sec)
              + TimeInterval(metadata.modificationTime.tv_nsec) / 1_000_000_000
          ),
          verifiedBytes: nil
        )
      }
      return result
    }

    static func recoverStagedDocuments(directory: URL, descriptor: Int32) throws {
      let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      guard names.count <= 1_024 else { throw GitEvidenceError.patchStoreCapacityExceeded }
      var markers = Set<String>()
      var transactions: [String: [(original: String, temporary: String)]] = [:]
      for name in names where name.hasPrefix(GitPatchStorePersistence.commitMarkerPrefix) {
        let transaction = String(name.dropFirst(GitPatchStorePersistence.commitMarkerPrefix.count))
        guard GitPatchStorePersistence.validTransactionID(transaction) else {
          throw GitEvidenceError.patchStoreCapacityExceeded
        }
        try validateCommitMarker(name, descriptor: descriptor)
        markers.insert(transaction)
      }
      for temporary in names where temporary.hasPrefix(GitPatchStorePersistence.trashPrefix) {
        let (transaction, original) = try GitPatchStorePersistence.parseTrashName(temporary)
        transactions[transaction, default: []].append((original, temporary))
      }
      var changed = false
      for (transaction, staged) in transactions {
        if markers.remove(transaction) != nil {
          guard
            GitPatchStoreTransactionsPOSIX.cleanupCommittedTransaction(
              transaction,
              staged: staged,
              descriptor: descriptor
            )
          else { throw GitEvidenceError.patchStoreCapacityExceeded }
        } else {
          for item in staged {
            var metadata = stat()
            guard fstatat(descriptor, item.original, &metadata, AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT,
              renameat(descriptor, item.temporary, descriptor, item.original) == 0
            else { throw GitEvidenceError.patchStoreCapacityExceeded }
          }
          changed = true
        }
      }
      for transaction in markers {
        guard
          GitPatchStoreTransactionsPOSIX.cleanupCommittedTransaction(
            transaction, staged: [], descriptor: descriptor)
        else {
          throw GitEvidenceError.patchStoreCapacityExceeded
        }
      }
      if changed, fsync(descriptor) != 0 {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
    }

    static func validateCommitMarker(_ name: String, descriptor: Int32) throws {
      let marker = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard marker >= 0 else { throw GitEvidenceError.patchStoreCapacityExceeded }
      defer { close(marker) }
      var metadata = stat()
      guard fstat(marker, &metadata) == 0, metadata.st_uid == getuid(),
        metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o777 == 0o600,
        metadata.st_size == 0
      else { throw GitEvidenceError.patchStoreCapacityExceeded }
    }

    static func write(_ bytes: Data, named name: String, to directory: Int32) throws {
      let descriptor = openat(
        directory,
        name,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        S_IRUSR | S_IWUSR
      )
      guard descriptor >= 0 else { throw GitEvidenceError.patchStoreCapacityExceeded }
      var shouldRemove = true
      defer {
        close(descriptor)
        if shouldRemove { _ = unlinkat(directory, name, 0) }
      }
      try bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
          let written = POSIXSystem.write(
            descriptor, buffer.baseAddress! + offset, buffer.count - offset)
          guard written > 0 else { throw GitEvidenceError.patchStoreCapacityExceeded }
          offset += written
        }
      }
      guard fsync(descriptor) == 0 else { throw GitEvidenceError.patchStoreCapacityExceeded }
      shouldRemove = false
    }

    static func readBounded(_ descriptor: Int32, expectedCount: Int) throws -> Data {
      var metadata = stat()
      guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(),
        metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o777 == 0o600,
        metadata.st_size == expectedCount
      else { throw GitEvidenceError.patchNotFound }
      var data = Data(count: expectedCount)
      let count = try data.withUnsafeMutableBytes { buffer in
        var offset = 0
        while offset < buffer.count {
          let received = POSIXSystem.read(
            descriptor,
            buffer.baseAddress! + offset,
            buffer.count - offset
          )
          guard received > 0 else { throw GitEvidenceError.patchNotFound }
          offset += received
        }
        return offset
      }
      guard count == expectedCount else { throw GitEvidenceError.patchNotFound }
      return data
    }
    static func writeDocument(_ bytes: Data, named name: String, to directory: Int32) throws {
      try write(bytes, named: name, to: directory)
      guard fsync(directory) == 0 else {
        _ = unlinkat(directory, name, 0)
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
    }

    static func loadAndVerify(
      _ identifier: String,
      document: GitPatchStoreDocument,
      descriptor: Int32
    ) throws -> Data {
      guard GitPatchStorePersistence.validIdentifier(identifier) else {
        throw GitEvidenceError.patchNotFound
      }
      let file = openat(descriptor, identifier, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard file >= 0 else { throw GitEvidenceError.patchNotFound }
      defer { close(file) }
      let bytes = try readBounded(file, expectedCount: document.byteCount)
      guard identifier.hasSuffix("_\(GitPatchStorePersistence.digest(for: bytes))") else {
        throw GitEvidenceError.patchNotFound
      }
      return bytes
    }

    static func persistLastAccess(
      _ identifier: String,
      document: GitPatchStoreDocument,
      descriptor: Int32
    ) throws {
      let file = openat(descriptor, identifier, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard file >= 0 else { throw GitEvidenceError.patchNotFound }
      defer { close(file) }
      var metadata = stat()
      guard fstat(file, &metadata) == 0, metadata.st_uid == getuid(),
        metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o777 == 0o600,
        metadata.st_size == document.byteCount,
        futimens(file, nil) == 0
      else { throw GitEvidenceError.patchNotFound }
    }

    static func rollbackDocument(_ identifier: String, descriptor: Int32) {
      _ = unlinkat(descriptor, identifier, 0)
      _ = fsync(descriptor)
    }

  }
#endif

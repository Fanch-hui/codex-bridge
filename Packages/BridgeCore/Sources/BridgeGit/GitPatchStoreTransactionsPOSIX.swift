#if !os(Windows)
  import Foundation
  import Darwin

  enum GitPatchStoreTransactionsPOSIX {
    static func withExclusiveLock<Result>(
      _ descriptor: Int32,
      _ body: () throws -> Result
    ) throws -> Result {
      GitPatchStorePersistence.processLock.lock()
      defer { GitPatchStorePersistence.processLock.unlock() }
      try acquireExclusiveLock(descriptor)
      defer { releaseLock(descriptor) }
      return try body()
    }

    static func acquireExclusiveLock(_ descriptor: Int32) throws {
      var lock = flock()
      lock.l_type = Int16(F_WRLCK)
      lock.l_whence = Int16(SEEK_SET)
      for _ in 0..<GitPatchStorePersistence.maximumLockAttempts {
        if fcntl(descriptor, F_SETLK, &lock) == 0 { return }
        guard errno == EACCES || errno == EAGAIN else {
          throw GitEvidenceError.patchStoreCapacityExceeded
        }
        Thread.sleep(
          forTimeInterval: Double(GitPatchStorePersistence.lockWaitNanoseconds) / 1_000_000_000)
      }
      throw GitEvidenceError.patchStoreCapacityExceeded
    }

    static func releaseLock(_ descriptor: Int32) {
      var lock = flock()
      lock.l_type = Int16(F_UNLCK)
      lock.l_whence = Int16(SEEK_SET)
      _ = fcntl(descriptor, F_SETLK, &lock)
    }

    static func trimLoadedDocuments(
      _ documents: inout [String: GitPatchStoreDocument],
      documentLimit: Int,
      storedBytesLimit: Int,
      descriptor: Int32,
      protecting protectedIdentifier: String? = nil
    ) throws {
      let plan = try GitPatchStorePersistence.trimPlan(
        for: documents,
        documentLimit: documentLimit,
        storedBytesLimit: storedBytesLimit,
        protecting: protectedIdentifier
      )
      guard !plan.victims.isEmpty else { return }
      try validateRemovable(plan.victims, descriptor: descriptor)
      try removeTransaction(plan.victims.map(\.0), descriptor: descriptor)
      documents = plan.remaining
    }

    static func validateRemovable(
      _ victims: [(String, GitPatchStoreDocument)],
      descriptor: Int32
    ) throws {
      let immutableFlags = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)
      for (identifier, document) in victims {
        let file = openat(descriptor, identifier, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw GitEvidenceError.patchStoreCapacityExceeded }
        defer { close(file) }
        var metadata = stat()
        guard fstat(file, &metadata) == 0, metadata.st_uid == getuid(),
          metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o777 == 0o600,
          metadata.st_size == document.byteCount,
          metadata.st_flags & immutableFlags == 0
        else { throw GitEvidenceError.patchStoreCapacityExceeded }
      }
    }
    static func removeTransaction(
      _ identifiers: [String],
      descriptor: Int32,
      committedRemovalHook: (([String]) -> Void)? = nil
    ) throws {
      let transaction = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
      var staged: [(original: String, temporary: String)] = []
      do {
        for identifier in identifiers {
          let temporary = "\(GitPatchStorePersistence.trashPrefix)\(transaction)_\(identifier)"
          guard renameat(descriptor, identifier, descriptor, temporary) == 0 else {
            throw GitEvidenceError.patchStoreCapacityExceeded
          }
          staged.append((identifier, temporary))
        }
        guard fsync(descriptor) == 0 else { throw GitEvidenceError.patchStoreCapacityExceeded }
        try writeCommitMarker(transaction, descriptor: descriptor)
      } catch {
        restoreStaged(staged, descriptor: descriptor)
        throw error
      }
      committedRemovalHook?(staged.map(\.temporary))
      _ = cleanupCommittedTransaction(transaction, staged: staged, descriptor: descriptor)
    }

    static func restoreStaged(
      _ staged: [(original: String, temporary: String)],
      descriptor: Int32
    ) {
      for item in staged.reversed() {
        _ = renameat(descriptor, item.temporary, descriptor, item.original)
      }
      _ = fsync(descriptor)
    }

    static func writeCommitMarker(_ transaction: String, descriptor: Int32) throws {
      let name = GitPatchStorePersistence.commitMarkerPrefix + transaction
      let marker = openat(
        descriptor,
        name,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        S_IRUSR | S_IWUSR
      )
      guard marker >= 0 else { throw GitEvidenceError.patchStoreCapacityExceeded }
      defer { close(marker) }
      guard fchmod(marker, S_IRUSR | S_IWUSR) == 0, fsync(marker) == 0,
        fsync(descriptor) == 0
      else {
        _ = unlinkat(descriptor, name, 0)
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
    }

    static func cleanupCommittedTransaction(
      _ transaction: String,
      staged: [(original: String, temporary: String)],
      descriptor: Int32
    ) -> Bool {
      for item in staged.sorted(by: { $0.temporary < $1.temporary }) {
        guard unlinkat(descriptor, item.temporary, 0) == 0 || errno == ENOENT else {
          return false
        }
      }
      let marker = GitPatchStorePersistence.commitMarkerPrefix + transaction
      guard unlinkat(descriptor, marker, 0) == 0 || errno == ENOENT else { return false }
      return fsync(descriptor) == 0
    }
  }
#endif

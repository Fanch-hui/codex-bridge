#if os(Windows)
  import Foundation
  import WinSDK

  enum GitPatchStorePersistenceWindows {
    static func openPrivateDirectory(_ url: URL) throws -> String {
      guard url.isFileURL else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      do {
        try FileManager.default.createDirectory(
          at: url,
          withIntermediateDirectories: true
        )
      } catch {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      // Windows uses ACLs; the POSIX owner/mode checks apply to POSIX only.
      guard
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
        attributes[.type] as? FileAttributeType == .typeDirectory
      else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      return url.path
    }

    static func openLockFile(in path: String) throws -> HANDLE {
      let lock = PatchStoreFile.openReadWriteOrCreate(
        path + "\\" + GitPatchStorePersistence.lockFileName)
      guard lock != INVALID_HANDLE_VALUE else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      return lock
    }

    static func loadDocuments(
      directory: URL,
      path: String
    ) throws -> [String: GitPatchStoreDocument] {
      try recoverStagedDocuments(directory: directory, path: path)
      let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
        $0 != GitPatchStorePersistence.lockFileName
      }
      guard names.count <= 1_024, names.allSatisfy(GitPatchStorePersistence.validIdentifier) else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      var result: [String: GitPatchStoreDocument] = [:]
      for name in names {
        let file = PatchStoreFile.openForReading(path + "\\" + name)
        guard file != INVALID_HANDLE_VALUE else {
          throw GitEvidenceError.patchStoreCapacityExceeded
        }
        defer { _ = CloseHandle(file) }
        // Windows uses ACLs; the POSIX owner/mode checks apply to POSIX only.
        guard let information = PatchStoreFile.information(file),
          PatchStoreFile.isRegularFile(information.attributes),
          information.size >= 0, let byteCount = Int(exactly: information.size)
        else { throw GitEvidenceError.patchStoreCapacityExceeded }
        result[name] = GitPatchStoreDocument(
          byteCount: byteCount,
          lastAccess: PatchStoreFile.date(lastWriteFileTime: information.lastWriteFileTime),
          verifiedBytes: nil
        )
      }
      return result
    }

    static func recoverStagedDocuments(directory: URL, path: String) throws {
      let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      guard names.count <= 1_024 else { throw GitEvidenceError.patchStoreCapacityExceeded }
      var markers = Set<String>()
      var transactions: [String: [(original: String, temporary: String)]] = [:]
      for name in names where name.hasPrefix(GitPatchStorePersistence.commitMarkerPrefix) {
        let transaction = String(name.dropFirst(GitPatchStorePersistence.commitMarkerPrefix.count))
        guard GitPatchStorePersistence.validTransactionID(transaction) else {
          throw GitEvidenceError.patchStoreCapacityExceeded
        }
        try validateCommitMarker(name, path: path)
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
            GitPatchStoreTransactionsWindows.cleanupCommittedTransaction(
              transaction,
              staged: staged,
              path: path
            )
          else { throw GitEvidenceError.patchStoreCapacityExceeded }
        } else {
          for item in staged {
            let originalAttributes = (path + "\\" + item.original)
              .withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
            guard originalAttributes == INVALID_FILE_ATTRIBUTES,
              GetLastError() == DWORD(ERROR_FILE_NOT_FOUND),
              PatchStoreFile.rename(path + "\\" + item.temporary, to: path + "\\" + item.original)
            else { throw GitEvidenceError.patchStoreCapacityExceeded }
          }
          changed = true
        }
      }
      for transaction in markers {
        guard
          GitPatchStoreTransactionsWindows.cleanupCommittedTransaction(
            transaction, staged: [], path: path)
        else {
          throw GitEvidenceError.patchStoreCapacityExceeded
        }
      }
      if changed, !PatchStoreFile.fsyncDirectory(path) {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
    }

    static func validateCommitMarker(_ name: String, path: String) throws {
      let marker = PatchStoreFile.openForReading(path + "\\" + name)
      guard marker != INVALID_HANDLE_VALUE else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      defer { _ = CloseHandle(marker) }
      // Windows uses ACLs; the POSIX owner/mode checks apply to POSIX only.
      guard let information = PatchStoreFile.information(marker),
        PatchStoreFile.isRegularFile(information.attributes),
        information.size == 0
      else { throw GitEvidenceError.patchStoreCapacityExceeded }
    }

    static func write(_ bytes: Data, named name: String, in path: String) throws {
      let handle = PatchStoreFile.createExclusive(path + "\\" + name)
      guard handle != INVALID_HANDLE_VALUE else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      var shouldRemove = true
      defer {
        _ = CloseHandle(handle)
        if shouldRemove { _ = PatchStoreFile.remove(path + "\\" + name) }
      }
      try bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
          var written: DWORD = 0
          let succeeded = WriteFile(
            handle,
            buffer.baseAddress! + offset,
            DWORD(buffer.count - offset),
            &written,
            nil
          )
          guard succeeded, written > 0 else {
            throw GitEvidenceError.patchStoreCapacityExceeded
          }
          offset += Int(written)
        }
      }
      guard PatchStoreFile.flush(handle) else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      shouldRemove = false
    }

    static func readBounded(_ handle: HANDLE, expectedCount: Int) throws -> Data {
      // Windows uses ACLs; the POSIX owner/mode checks apply to POSIX only.
      guard let information = PatchStoreFile.information(handle),
        PatchStoreFile.isRegularFile(information.attributes),
        information.size == expectedCount
      else { throw GitEvidenceError.patchNotFound }
      guard let data = PatchStoreFile.read(handle, expectedCount: expectedCount) else {
        throw GitEvidenceError.patchNotFound
      }
      return data
    }
    static func writeDocument(_ bytes: Data, named name: String, in path: String) throws {
      try write(bytes, named: name, in: path)
      guard PatchStoreFile.fsyncDirectory(path) else {
        _ = PatchStoreFile.remove(path + "\\" + name)
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
    }

    static func loadAndVerify(
      _ identifier: String,
      document: GitPatchStoreDocument,
      path: String
    ) throws -> Data {
      guard GitPatchStorePersistence.validIdentifier(identifier) else {
        throw GitEvidenceError.patchNotFound
      }
      let handle = PatchStoreFile.openForReading(path + "\\" + identifier)
      guard handle != INVALID_HANDLE_VALUE else { throw GitEvidenceError.patchNotFound }
      defer { _ = CloseHandle(handle) }
      let bytes = try readBounded(handle, expectedCount: document.byteCount)
      guard identifier.hasSuffix("_\(GitPatchStorePersistence.digest(for: bytes))") else {
        throw GitEvidenceError.patchNotFound
      }
      return bytes
    }

    static func persistLastAccess(
      _ identifier: String,
      document: GitPatchStoreDocument,
      path: String
    ) throws {
      let handle = PatchStoreFile.openForReading(path + "\\" + identifier)
      guard handle != INVALID_HANDLE_VALUE else { throw GitEvidenceError.patchNotFound }
      defer { _ = CloseHandle(handle) }
      guard let information = PatchStoreFile.information(handle),
        PatchStoreFile.isRegularFile(information.attributes),
        information.size == document.byteCount,
        PatchStoreFile.touchLastWrite(handle)
      else { throw GitEvidenceError.patchNotFound }
    }

    static func rollbackDocument(_ identifier: String, path: String) {
      _ = PatchStoreFile.remove(path + "\\" + identifier)
      _ = PatchStoreFile.fsyncDirectory(path)
    }

  }
#endif

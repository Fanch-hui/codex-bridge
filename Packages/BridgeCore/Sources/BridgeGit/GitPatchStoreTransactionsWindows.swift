#if os(Windows)
  import Foundation
  import WinSDK

  enum GitPatchStoreTransactionsWindows {
    static func withExclusiveLock<Result>(
      _ lock: HANDLE,
      _ body: () throws -> Result
    ) throws -> Result {
      GitPatchStorePersistence.processLock.lock()
      defer { GitPatchStorePersistence.processLock.unlock() }
      guard PatchStoreFile.acquireExclusiveLock(lock) else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      defer { PatchStoreFile.releaseLock(lock) }
      return try body()
    }
    static func trimLoadedDocuments(
      _ documents: inout [String: GitPatchStoreDocument],
      documentLimit: Int,
      storedBytesLimit: Int,
      path: String,
      protecting protectedIdentifier: String? = nil
    ) throws {
      let plan = try GitPatchStorePersistence.trimPlan(
        for: documents,
        documentLimit: documentLimit,
        storedBytesLimit: storedBytesLimit,
        protecting: protectedIdentifier
      )
      guard !plan.victims.isEmpty else { return }
      try validateRemovable(plan.victims, path: path)
      try removeTransaction(plan.victims.map(\.0), path: path)
      documents = plan.remaining
    }

    static func validateRemovable(
      _ victims: [(String, GitPatchStoreDocument)],
      path: String
    ) throws {
      // Windows uses ACLs; the POSIX owner/mode/immutable-flag checks apply to
      // POSIX only.
      for (identifier, document) in victims {
        let file = PatchStoreFile.openForReading(path + "\\" + identifier)
        guard file != INVALID_HANDLE_VALUE else {
          throw GitEvidenceError.patchStoreCapacityExceeded
        }
        defer { _ = CloseHandle(file) }
        guard let information = PatchStoreFile.information(file),
          PatchStoreFile.isRegularFile(information.attributes),
          information.size == document.byteCount
        else { throw GitEvidenceError.patchStoreCapacityExceeded }
      }
    }
    static func removeTransaction(
      _ identifiers: [String],
      path: String,
      committedRemovalHook: (([String]) -> Void)? = nil
    ) throws {
      let transaction = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
      var staged: [(original: String, temporary: String)] = []
      do {
        for identifier in identifiers {
          let temporary = "\(GitPatchStorePersistence.trashPrefix)\(transaction)_\(identifier)"
          guard PatchStoreFile.rename(path + "\\" + identifier, to: path + "\\" + temporary)
          else {
            throw GitEvidenceError.patchStoreCapacityExceeded
          }
          staged.append((identifier, temporary))
        }
        guard PatchStoreFile.fsyncDirectory(path) else {
          throw GitEvidenceError.patchStoreCapacityExceeded
        }
        try writeCommitMarker(transaction, path: path)
      } catch {
        restoreStaged(staged, path: path)
        throw error
      }
      committedRemovalHook?(staged.map(\.temporary))
      _ = cleanupCommittedTransaction(transaction, staged: staged, path: path)
    }

    static func restoreStaged(
      _ staged: [(original: String, temporary: String)],
      path: String
    ) {
      for item in staged.reversed() {
        _ = PatchStoreFile.rename(path + "\\" + item.temporary, to: path + "\\" + item.original)
      }
      _ = PatchStoreFile.fsyncDirectory(path)
    }

    static func writeCommitMarker(_ transaction: String, path: String) throws {
      let name = GitPatchStorePersistence.commitMarkerPrefix + transaction
      let marker = PatchStoreFile.createExclusive(path + "\\" + name)
      guard marker != INVALID_HANDLE_VALUE else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      defer { _ = CloseHandle(marker) }
      guard PatchStoreFile.flush(marker), PatchStoreFile.fsyncDirectory(path) else {
        _ = PatchStoreFile.remove(path + "\\" + name)
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
    }

    static func cleanupCommittedTransaction(
      _ transaction: String,
      staged: [(original: String, temporary: String)],
      path: String
    ) -> Bool {
      for item in staged.sorted(by: { $0.temporary < $1.temporary }) {
        guard
          PatchStoreFile.remove(path + "\\" + item.temporary)
            || GetLastError() == DWORD(ERROR_FILE_NOT_FOUND)
        else { return false }
      }
      let marker = GitPatchStorePersistence.commitMarkerPrefix + transaction
      guard
        PatchStoreFile.remove(path + "\\" + marker)
          || GetLastError() == DWORD(ERROR_FILE_NOT_FOUND)
      else { return false }
      return PatchStoreFile.fsyncDirectory(path)
    }
  }
#endif

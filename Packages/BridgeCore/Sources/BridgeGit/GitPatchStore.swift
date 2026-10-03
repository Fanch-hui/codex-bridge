import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public actor GitPatchStore {
  private let maximumDocumentCount: Int
  private let maximumStoredBytes: Int
  private let maximumPageBytes: Int
  private let persistentDirectory: URL?
  #if os(Windows)
    private var directoryPath: String?
    private var lockHandle: PatchStoreLockHandle?
  #else
    private let directoryDescriptor: Int32?
    private let lockDescriptor: Int32?
  #endif
  private let committedRemovalHook: (@Sendable (URL, [String]) -> Void)?
  private var documents: [String: GitPatchStoreDocument]
  private var storedBytes: Int

  public init(
    maximumDocumentCount: Int = 64,
    maximumStoredBytes: Int = 64 * 1_024 * 1_024,
    maximumPageBytes: Int = 200 * 1_024
  ) {
    self.maximumDocumentCount = max(1, maximumDocumentCount)
    self.maximumStoredBytes = max(1, maximumStoredBytes)
    self.maximumPageBytes = max(1, maximumPageBytes)
    persistentDirectory = nil
    #if os(Windows)
      directoryPath = nil
      lockHandle = nil
    #else
      directoryDescriptor = nil
      lockDescriptor = nil
    #endif
    committedRemovalHook = nil
    documents = [:]
    storedBytes = 0
  }

  public init(
    persistentDirectory: URL,
    maximumDocumentCount: Int = 64,
    maximumStoredBytes: Int = 64 * 1_024 * 1_024,
    maximumPageBytes: Int = 200 * 1_024
  ) throws {
    try self.init(
      persistentDirectory: persistentDirectory,
      maximumDocumentCount: maximumDocumentCount,
      maximumStoredBytes: maximumStoredBytes,
      maximumPageBytes: maximumPageBytes,
      committedRemovalHook: nil
    )
  }

  init(
    persistentDirectory: URL,
    maximumDocumentCount: Int,
    maximumStoredBytes: Int,
    maximumPageBytes: Int,
    committedRemovalHook: (@Sendable (URL, [String]) -> Void)?
  ) throws {
    let documentLimit = max(1, maximumDocumentCount)
    let storedBytesLimit = max(1, maximumStoredBytes)
    self.maximumDocumentCount = documentLimit
    self.maximumStoredBytes = storedBytesLimit
    self.maximumPageBytes = max(1, maximumPageBytes)
    #if os(Windows)
      let directory = try GitPatchStorePersistenceWindows.openPrivateDirectory(persistentDirectory)
      let lock = try GitPatchStorePersistenceWindows.openLockFile(in: directory)
      do {
        let bounded = try GitPatchStoreTransactionsWindows.withExclusiveLock(lock) {
          var loaded = try GitPatchStorePersistenceWindows.loadDocuments(
            directory: persistentDirectory, path: directory)
          try GitPatchStoreTransactionsWindows.trimLoadedDocuments(
            &loaded,
            documentLimit: documentLimit,
            storedBytesLimit: storedBytesLimit,
            path: directory
          )
          return loaded
        }
        self.persistentDirectory = persistentDirectory
        directoryPath = directory
        self.committedRemovalHook = committedRemovalHook
        documents = bounded
        storedBytes = try GitPatchStorePersistence.totalBytes(in: bounded)
        lockHandle = PatchStoreLockHandle(lock)
      } catch {
        PatchStoreFile.close(lock)
        throw error
      }
    #else
      let descriptor = try GitPatchStorePersistencePOSIX.openPrivateDirectory(persistentDirectory)
      let lock = try GitPatchStorePersistencePOSIX.openLockFile(in: descriptor)
      do {
        let bounded = try GitPatchStoreTransactionsPOSIX.withExclusiveLock(lock) {
          var loaded = try GitPatchStorePersistencePOSIX.loadDocuments(
            directory: persistentDirectory,
            descriptor: descriptor
          )
          try GitPatchStoreTransactionsPOSIX.trimLoadedDocuments(
            &loaded,
            documentLimit: documentLimit,
            storedBytesLimit: storedBytesLimit,
            descriptor: descriptor
          )
          return loaded
        }
        self.persistentDirectory = persistentDirectory
        directoryDescriptor = descriptor
        lockDescriptor = lock
        self.committedRemovalHook = committedRemovalHook
        documents = bounded
        storedBytes = try GitPatchStorePersistence.totalBytes(in: bounded)
      } catch {
        close(lock)
        close(descriptor)
        throw error
      }
    #endif
  }

  deinit {
    #if !os(Windows)
      if let lockDescriptor { close(lockDescriptor) }
      if let directoryDescriptor { close(directoryDescriptor) }
    #endif
  }

  func store(_ bytes: Data, isTruncated: Bool) throws -> GitPatchHandle {
    try withStoreLock {
      try reloadPersistentDocuments()
      return try storeLocked(bytes, isTruncated: isTruncated)
    }
  }

  private func storeLocked(_ bytes: Data, isTruncated: Bool) throws -> GitPatchHandle {
    guard bytes.count <= maximumStoredBytes else {
      throw GitEvidenceError.patchStoreCapacityExceeded
    }
    let identifier = GitPatchStorePersistence.identifier(for: bytes)
    if let existing = documents[identifier] {
      guard existing.byteCount == bytes.count else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      documents[identifier]?.lastAccess = Date()
      return GitPatchHandle(
        rawValue: identifier,
        totalBytes: bytes.count,
        isTruncated: isTruncated
      )
    }
    #if os(Windows)
      if let directoryPath {
        try GitPatchStorePersistenceWindows.writeDocument(
          bytes, named: identifier, in: directoryPath)
      }
      documents[identifier] = GitPatchStoreDocument(
        byteCount: bytes.count,
        lastAccess: Date(),
        verifiedBytes: directoryPath == nil ? bytes : nil
      )
    #else
      if let directoryDescriptor {
        try GitPatchStorePersistencePOSIX.writeDocument(
          bytes, named: identifier, to: directoryDescriptor)
      }
      documents[identifier] = GitPatchStoreDocument(
        byteCount: bytes.count,
        lastAccess: Date(),
        verifiedBytes: directoryDescriptor == nil ? bytes : nil
      )
    #endif
    storedBytes += bytes.count
    do {
      try trimToLimits(protecting: identifier)
    } catch {
      rollbackNewDocument(identifier)
      throw error
    }
    return GitPatchHandle(
      rawValue: identifier,
      totalBytes: bytes.count,
      isTruncated: isTruncated
    )
  }

  public func page(
    for handle: GitPatchHandle,
    offset: Int = 0,
    maximumBytes requestedMaximumBytes: Int? = nil
  ) throws -> GitPatchPage {
    try withStoreLock {
      try reloadPersistentDocuments()
      return try pageLocked(
        for: handle,
        offset: offset,
        maximumBytes: requestedMaximumBytes
      )
    }
  }

  private func pageLocked(
    for handle: GitPatchHandle,
    offset: Int,
    maximumBytes requestedMaximumBytes: Int?
  ) throws -> GitPatchPage {
    guard var document = documents[handle.rawValue], document.byteCount == handle.totalBytes else {
      throw GitEvidenceError.patchNotFound
    }
    guard offset >= 0, offset <= document.byteCount else {
      throw GitEvidenceError.invalidPatchCursor
    }
    let bytes: Data
    if let verifiedBytes = document.verifiedBytes {
      bytes = verifiedBytes
    } else {
      bytes = try loadAndVerify(handle.rawValue, document: document)
      document.verifiedBytes = bytes
    }
    let requested = requestedMaximumBytes.map { max(1, $0) } ?? maximumPageBytes
    let pageBytes = min(requested, maximumPageBytes)
    let end = min(bytes.count, offset + pageBytes)
    document.lastAccess = Date()
    documents[handle.rawValue] = document
    try persistLastAccess(handle.rawValue, document: document)
    return GitPatchPage(
      bytes: Data(bytes[offset..<end]),
      nextOffset: end < bytes.count ? end : nil,
      totalBytes: bytes.count,
      isTruncated: handle.isTruncated
    )
  }

  public func discard(_ handle: GitPatchHandle) {
    _ = try? remove(handle)
  }

  @discardableResult
  public func remove(_ handle: GitPatchHandle) throws -> Bool {
    try Self.validate(handle)
    return try withStoreLock {
      try reloadPersistentDocuments()
      guard let document = documents[handle.rawValue] else { return false }
      guard document.byteCount == handle.totalBytes else {
        throw GitEvidenceError.patchNotFound
      }
      #if os(Windows)
        if let directoryPath {
          try GitPatchStoreTransactionsWindows.validateRemovable(
            [(handle.rawValue, document)], path: directoryPath)
          let hook: (([String]) -> Void)?
          if let committedRemovalHook, let persistentDirectory {
            hook = { temporaryNames in
              committedRemovalHook(persistentDirectory, temporaryNames)
            }
          } else {
            hook = nil
          }
          try GitPatchStoreTransactionsWindows.removeTransaction(
            [handle.rawValue],
            path: directoryPath,
            committedRemovalHook: hook
          )
        }
      #else
        if let directoryDescriptor {
          try GitPatchStoreTransactionsPOSIX.validateRemovable(
            [(handle.rawValue, document)],
            descriptor: directoryDescriptor
          )
          let hook: (([String]) -> Void)?
          if let committedRemovalHook, let persistentDirectory {
            hook = { temporaryNames in
              committedRemovalHook(persistentDirectory, temporaryNames)
            }
          } else {
            hook = nil
          }
          try GitPatchStoreTransactionsPOSIX.removeTransaction(
            [handle.rawValue],
            descriptor: directoryDescriptor,
            committedRemovalHook: hook
          )
        }
      #endif
      documents[handle.rawValue] = nil
      storedBytes -= document.byteCount
      return true
    }
  }

  public func discardAll() {
    do {
      try withStoreLock {
        try reloadPersistentDocuments()
        let victims = Array(documents)
        #if os(Windows)
          if let directoryPath, !victims.isEmpty {
            try GitPatchStoreTransactionsWindows.validateRemovable(victims, path: directoryPath)
            try GitPatchStoreTransactionsWindows.removeTransaction(
              victims.map(\.key), path: directoryPath)
          }
        #else
          if let directoryDescriptor, !victims.isEmpty {
            try GitPatchStoreTransactionsPOSIX.validateRemovable(
              victims, descriptor: directoryDescriptor)
            try GitPatchStoreTransactionsPOSIX.removeTransaction(
              victims.map(\.key), descriptor: directoryDescriptor)
          }
        #endif
        documents.removeAll(keepingCapacity: false)
        storedBytes = 0
      }
    } catch {}
  }

  private func loadAndVerify(_ identifier: String, document: GitPatchStoreDocument) throws -> Data {
    #if os(Windows)
      guard let directoryPath else { throw GitEvidenceError.patchNotFound }
      return try GitPatchStorePersistenceWindows.loadAndVerify(
        identifier,
        document: document,
        path: directoryPath
      )
    #else
      guard let directoryDescriptor else { throw GitEvidenceError.patchNotFound }
      return try GitPatchStorePersistencePOSIX.loadAndVerify(
        identifier,
        document: document,
        descriptor: directoryDescriptor
      )
    #endif
  }

  private func persistLastAccess(_ identifier: String, document: GitPatchStoreDocument) throws {
    #if os(Windows)
      guard let directoryPath else { return }
      try GitPatchStorePersistenceWindows.persistLastAccess(
        identifier,
        document: document,
        path: directoryPath
      )
    #else
      guard let directoryDescriptor else { return }
      try GitPatchStorePersistencePOSIX.persistLastAccess(
        identifier,
        document: document,
        descriptor: directoryDescriptor
      )
    #endif
  }

  private func trimToLimits(protecting identifier: String) throws {
    #if os(Windows)
      guard let directoryPath else {
        while documents.count > maximumDocumentCount || storedBytes > maximumStoredBytes {
          guard
            let oldest = documents.filter({ $0.key != identifier }).min(by: {
              $0.value.lastAccess < $1.value.lastAccess
            })
          else { throw GitEvidenceError.patchStoreCapacityExceeded }
          documents[oldest.key] = nil
          storedBytes -= oldest.value.byteCount
        }
        return
      }
      try GitPatchStoreTransactionsWindows.trimLoadedDocuments(
        &documents,
        documentLimit: maximumDocumentCount,
        storedBytesLimit: maximumStoredBytes,
        path: directoryPath,
        protecting: identifier
      )
      storedBytes = try GitPatchStorePersistence.totalBytes(in: documents)
    #else
      guard let directoryDescriptor else {
        while documents.count > maximumDocumentCount || storedBytes > maximumStoredBytes {
          guard
            let oldest = documents.filter({ $0.key != identifier }).min(by: {
              $0.value.lastAccess < $1.value.lastAccess
            })
          else { throw GitEvidenceError.patchStoreCapacityExceeded }
          documents[oldest.key] = nil
          storedBytes -= oldest.value.byteCount
        }
        return
      }
      try GitPatchStoreTransactionsPOSIX.trimLoadedDocuments(
        &documents,
        documentLimit: maximumDocumentCount,
        storedBytesLimit: maximumStoredBytes,
        descriptor: directoryDescriptor,
        protecting: identifier
      )
      storedBytes = try GitPatchStorePersistence.totalBytes(in: documents)
    #endif
  }

  private func rollbackNewDocument(_ identifier: String) {
    guard let document = documents.removeValue(forKey: identifier) else { return }
    storedBytes -= document.byteCount
    #if os(Windows)
      guard let directoryPath else { return }
      GitPatchStorePersistenceWindows.rollbackDocument(identifier, path: directoryPath)
    #else
      guard let directoryDescriptor else { return }
      GitPatchStorePersistencePOSIX.rollbackDocument(identifier, descriptor: directoryDescriptor)
    #endif
  }

  private func withStoreLock<Result>(_ body: () throws -> Result) throws -> Result {
    #if os(Windows)
      guard let lockHandle else { return try body() }
      return try GitPatchStoreTransactionsWindows.withExclusiveLock(lockHandle.raw, body)
    #else
      guard let lockDescriptor else { return try body() }
      return try GitPatchStoreTransactionsPOSIX.withExclusiveLock(lockDescriptor, body)
    #endif
  }

  private func reloadPersistentDocuments() throws {
    guard let persistentDirectory else { return }
    #if os(Windows)
      guard let directoryPath else { return }
      let cached = documents
      var loaded = try GitPatchStorePersistenceWindows.loadDocuments(
        directory: persistentDirectory, path: directoryPath)
    #else
      guard let directoryDescriptor else { return }
      let cached = documents
      var loaded = try GitPatchStorePersistencePOSIX.loadDocuments(
        directory: persistentDirectory,
        descriptor: directoryDescriptor
      )
    #endif
    for (identifier, document) in cached {
      guard loaded[identifier]?.byteCount == document.byteCount else { continue }
      loaded[identifier]?.verifiedBytes = document.verifiedBytes
    }
    documents = loaded
    storedBytes = try GitPatchStorePersistence.totalBytes(in: loaded)
  }

  package static func validate(_ handle: GitPatchHandle) throws {
    try GitPatchStorePersistence.validate(handle)
  }
}

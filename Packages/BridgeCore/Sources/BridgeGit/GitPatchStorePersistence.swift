import Crypto
import Foundation

struct GitPatchStoreDocument: Sendable {
  let byteCount: Int
  var lastAccess: Date
  var verifiedBytes: Data?
}

enum GitPatchStorePersistence {
  static let processLock = NSLock()
  static let lockWaitNanoseconds: UInt64 = 10_000_000
  static let maximumLockAttempts = 500
  static let lockFileName = ".patch-store.lock"
  static let commitMarkerPrefix = ".commit_"
  static let trashPrefix = ".trash_"

  struct TrimPlan {
    let remaining: [String: GitPatchStoreDocument]
    let victims: [(String, GitPatchStoreDocument)]
  }

  static func totalBytes(in documents: [String: GitPatchStoreDocument]) throws -> Int {
    try documents.values.reduce(into: 0) { total, document in
      let addition = total.addingReportingOverflow(document.byteCount)
      guard !addition.overflow else { throw GitEvidenceError.patchStoreCapacityExceeded }
      total = addition.partialValue
    }
  }

  static func trimPlan(
    for documents: [String: GitPatchStoreDocument],
    documentLimit: Int,
    storedBytesLimit: Int,
    protecting protectedIdentifier: String?
  ) throws -> TrimPlan {
    var remaining = documents
    var remainingBytes = try totalBytes(in: remaining)
    var victims: [(String, GitPatchStoreDocument)] = []
    while remaining.count > documentLimit || remainingBytes > storedBytesLimit {
      guard
        let victim = remaining.filter({ $0.key != protectedIdentifier }).min(by: {
          let leftOversized = $0.value.byteCount > storedBytesLimit
          let rightOversized = $1.value.byteCount > storedBytesLimit
          if leftOversized != rightOversized { return leftOversized }
          return $0.value.lastAccess < $1.value.lastAccess
        })
      else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      victims.append(victim)
      remaining[victim.key] = nil
      remainingBytes -= victim.value.byteCount
    }
    return TrimPlan(remaining: remaining, victims: victims)
  }

  static func identifier(for bytes: Data) -> String {
    let random = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    return "patch_\(random)_\(digest(for: bytes))"
  }

  static func digest(for bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  static func validIdentifier(_ value: String) -> Bool {
    let parts = value.split(separator: "_", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "patch", parts[1].count == 32, parts[2].count == 64
    else { return false }
    return parts.dropFirst().joined().unicodeScalars.allSatisfy {
      CharacterSet(charactersIn: "0123456789abcdef").contains($0)
    }
  }

  static func validTransactionID(_ value: String) -> Bool {
    value.count == 32
      && value.unicodeScalars.allSatisfy {
        CharacterSet(charactersIn: "0123456789abcdef").contains($0)
      }
  }

  static func parseTrashName(_ temporary: String) throws -> (String, String) {
    let remainder = temporary.dropFirst(trashPrefix.count)
    guard let separator = remainder.firstIndex(of: "_") else {
      throw GitEvidenceError.patchStoreCapacityExceeded
    }
    let transaction = String(remainder[..<separator])
    let original = String(remainder[remainder.index(after: separator)...])
    guard validTransactionID(transaction), validIdentifier(original) else {
      throw GitEvidenceError.patchStoreCapacityExceeded
    }
    return (transaction, original)
  }

  static func validate(_ handle: GitPatchHandle) throws {
    guard validIdentifier(handle.rawValue), handle.totalBytes >= 0 else {
      throw GitEvidenceError.patchNotFound
    }
  }
}

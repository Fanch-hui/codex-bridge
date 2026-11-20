import Foundation

public enum ChunkedSecretStoreError: Error, Equatable, Sendable {
  /// The backend could not confirm whether a single-item write took effect.
  case commitUnknown
}

/// Stores large values in system credentials while publishing them with one root write.
public final class ChunkedSecretStore: SecretStore, Sendable {
  public static let maximumSecretBytes = 4 * 1024 * 1024
  private static let chunkBytes = 2_048
  private static let marker = Data([0, 255, 0] + Array("CodexBridgeChunks.v1\n".utf8))
  private static let stagingReference = SecretReference(rawValue: "bridge-chunked.staging.v1")
  private static let lock = NSLock()

  private let base: any SecretStore

  public init(base: any SecretStore) {
    self.base = base
  }

  public func load(_ reference: SecretReference) throws -> Data {
    try Self.lock.withLock {
      try requireRoot(reference)
      switch try readRoot(reference) {
      case .missing: throw SecretStoreError.notFound
      case .legacy(let data): return data
      case .manifest(let manifest):
        guard let active = manifest.active else { throw SecretStoreError.notFound }
        return try readChunks(active)
      }
    }
  }

  public func store(_ secret: Data, for reference: SecretReference) throws {
    guard !secret.isEmpty, secret.count <= Self.maximumSecretBytes else {
      throw SecretStoreError.invalidSecret
    }
    try Self.lock.withLock {
      try requireRoot(reference)
      try recoverStaging()
      let old = try clearPending(try readRoot(reference), at: reference)
      let generation = Generation(id: UUID(), length: secret.count)
      let stage = Stage(reference: reference.rawValue, generation: generation)
      try writeChecked(try JSONEncoder().encode(stage), for: Self.stagingReference)
      do {
        try writeChunks(secret, generation: generation)
        let manifest = Manifest(active: generation, pending: old.active.map { [$0] } ?? [])
        try writeManifest(manifest, for: reference)
        finishCommitted(manifest, at: reference, clearStaging: true)
      } catch {
        // The staging record keeps any uncommitted chunks discoverable for recovery.
        do { try recoverStaging() } catch {}
        throw error
      }
    }
  }

  public func remove(_ reference: SecretReference) throws {
    try Self.lock.withLock {
      try requireRoot(reference)
      let initial = try readRoot(reference)
      if case .missing = initial {
        do { try recoverStaging() } catch {}
        return
      }
      if case .manifest(let manifest) = initial, manifest.active == nil {
        finishCommitted(manifest, at: reference, clearStaging: false)
        return
      }
      try recoverStaging()
      switch try readRoot(reference) {
      case .missing: return
      case .legacy:
        try removeChecked(reference)
      case .manifest(let old):
        guard let active = old.active else {
          finishCommitted(old, at: reference, clearStaging: false)
          return
        }
        let tombstone = Manifest(active: nil, pending: old.pending + [active])
        try writeManifest(tombstone, for: reference)
        finishCommitted(tombstone, at: reference, clearStaging: false)
      }
    }
  }

  private func requireRoot(_ reference: SecretReference) throws {
    guard reference != Self.stagingReference else { throw SecretStoreError.invalidReference }
  }

  private enum Root {
    case missing
    case legacy(Data)
    case manifest(Manifest)

    var active: Generation? {
      guard case .manifest(let manifest) = self else { return nil }
      return manifest.active
    }
  }

  private struct Generation: Codable, Equatable {
    let id: UUID
    let length: Int

    var count: Int { (length + ChunkedSecretStore.chunkBytes - 1) / ChunkedSecretStore.chunkBytes }
    var valid: Bool { length > 0 && length <= ChunkedSecretStore.maximumSecretBytes }
  }

  private struct Manifest: Codable {
    var version: Int = 1
    let active: Generation?
    let pending: [Generation]

    var valid: Bool {
      guard version == 1, pending.count <= 2,
        active?.valid ?? true, pending.allSatisfy(\.valid)
      else { return false }
      let ids = pending.map(\.id) + (active.map { [$0.id] } ?? [])
      return Set(ids).count == ids.count
    }
  }

  private struct Stage: Codable {
    var version: Int = 1
    let reference: String
    let generation: Generation
  }

  private func readRoot(_ reference: SecretReference) throws -> Root {
    let data: Data
    do { data = try base.load(reference) } catch SecretStoreError.notFound { return .missing }
    guard data.starts(with: Self.marker) else { return .legacy(data) }
    guard
      let manifest = try? JSONDecoder().decode(
        Manifest.self, from: Data(data.dropFirst(Self.marker.count))), manifest.valid
    else { throw SecretStoreError.invalidStoredValue }
    return .manifest(manifest)
  }

  private func writeManifest(_ manifest: Manifest, for reference: SecretReference) throws {
    guard manifest.valid else { throw SecretStoreError.invalidStoredValue }
    let data = Self.marker + (try JSONEncoder().encode(manifest))
    try writeChecked(data, for: reference)
  }

  private func writeChunks(_ secret: Data, generation: Generation) throws {
    for index in 0..<generation.count {
      let start = index * Self.chunkBytes
      let end = min(start + Self.chunkBytes, secret.count)
      try base.store(secret.subdata(in: start..<end), for: chunkReference(generation, index))
    }
  }

  private func readChunks(_ generation: Generation) throws -> Data {
    var result = Data()
    result.reserveCapacity(generation.length)
    for index in 0..<generation.count {
      let data: Data
      do { data = try base.load(chunkReference(generation, index)) } catch SecretStoreError.notFound
      { throw SecretStoreError.invalidStoredValue }
      let expected = min(Self.chunkBytes, generation.length - result.count)
      guard data.count == expected else { throw SecretStoreError.invalidStoredValue }
      result.append(data)
    }
    return result
  }

  private func chunkReference(_ generation: Generation, _ index: Int) -> SecretReference {
    SecretReference(rawValue: "bridge-chunk.\(generation.id.uuidString.lowercased()).\(index)")
  }

  private func cleanup(_ generations: [Generation]) throws {
    for generation in generations {
      for index in 0..<generation.count {
        try removeIfPresent(chunkReference(generation, index))
      }
    }
  }

  private func clearPending(_ root: Root, at reference: SecretReference) throws -> Root {
    guard case .manifest(let manifest) = root, !manifest.pending.isEmpty else { return root }
    try cleanup(manifest.pending)
    let cleaned = Manifest(active: manifest.active, pending: [])
    try writeManifest(cleaned, for: reference)
    return .manifest(cleaned)
  }

  private func recoverStaging() throws {
    let data: Data
    do { data = try base.load(Self.stagingReference) } catch SecretStoreError.notFound { return }
    guard let stage = try? JSONDecoder().decode(Stage.self, from: data), stage.version == 1,
      stage.generation.valid,
      let reference = try? SecretReference(validating: stage.reference),
      reference != Self.stagingReference
    else { throw SecretStoreError.invalidStoredValue }
    let root = try readRoot(reference)
    if root.active != stage.generation { try cleanup([stage.generation]) }
    try removeIfPresent(Self.stagingReference)
  }

  private func finishCommitted(
    _ manifest: Manifest, at reference: SecretReference, clearStaging: Bool
  ) {
    // These markers survive failure so a later mutation can finish cleanup.
    if clearStaging { do { try removeIfPresent(Self.stagingReference) } catch {} }
    do {
      try cleanup(manifest.pending)
      if manifest.active == nil {
        try removeIfPresent(reference)
      } else if !manifest.pending.isEmpty {
        try writeManifest(Manifest(active: manifest.active, pending: []), for: reference)
      }
    } catch {}
  }

  private func writeChecked(_ data: Data, for reference: SecretReference) throws {
    do { try base.store(data, for: reference) } catch {
      let original = error
      let observed: Data?
      do { observed = try base.load(reference) } catch SecretStoreError.notFound {
        observed = nil
      } catch { throw ChunkedSecretStoreError.commitUnknown }
      if observed != data { throw original }
    }
  }

  private func removeChecked(_ reference: SecretReference) throws {
    do { try removeIfPresent(reference) } catch {
      let original = error
      do { _ = try base.load(reference) } catch SecretStoreError.notFound { return } catch {
        throw ChunkedSecretStoreError.commitUnknown
      }
      throw original
    }
  }

  private func removeIfPresent(_ reference: SecretReference) throws {
    do { try base.remove(reference) } catch SecretStoreError.notFound {}
  }
}

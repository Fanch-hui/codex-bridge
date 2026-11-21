import Foundation

extension EmbeddedDSHRuntimeResources {
  /// Validates the runtime once per process and shares the result between the workbench host,
  /// the providers-only host and the model gateway. A full validation hashes every bundled file,
  /// which costs seconds; later callers only re-check the entrypoints that are actually executed
  /// and fall back to a full validation when those changed.
  package static func shared(root: URL) async throws -> Self {
    try await EmbeddedDSHRuntimeResourceCache.shared.resources(root: root)
  }
}

private actor EmbeddedDSHRuntimeResourceCache {
  static let shared = EmbeddedDSHRuntimeResourceCache()

  private var validated: [String: EmbeddedDSHRuntimeResources] = [:]
  private var loading: [String: Task<EmbeddedDSHRuntimeResources, any Error>] = [:]

  func resources(root: URL) async throws -> EmbeddedDSHRuntimeResources {
    let key = root.resolvingSymlinksInPath().standardizedFileURL.path
    if let cached = validated[key] {
      if (try? cached.validateEntrypoints()) != nil { return cached }
      validated[key] = nil
    }
    if let pending = loading[key] { return try await pending.value }
    // Startup waits on this, so it must not be demoted to efficiency cores.
    let task = Task.detached(priority: .userInitiated) {
      try EmbeddedDSHRuntimeResources.load(root: root)
    }
    loading[key] = task
    defer { loading[key] = nil }
    let value = try await task.value
    validated[key] = value
    return value
  }
}

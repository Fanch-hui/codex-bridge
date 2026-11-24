import BridgeEmbeddedDSH
import BridgeSecurity
import Foundation

public struct ProviderRuntimeResources: Sendable {
  public let root: URL
  public let node: URL
  public let communityEntry: URL
  public let protocolExecutable: URL
  public let agentEditorEntry: URL
  public let installationEntry: URL
  public let catalog: URL
  private let runtime: EmbeddedDSHRuntimeResources
  private let snapshots: [SecureFileArtifactSnapshot]

  public static func load(root: URL) throws -> Self {
    try make(runtime: EmbeddedDSHRuntimeResources.load(root: root))
  }

  /// Reuses the process-wide runtime validation shared with the embedded engine hosts.
  public static func shared(root: URL) async throws -> Self {
    try make(runtime: await EmbeddedDSHRuntimeResources.shared(root: root))
  }

  private static func make(runtime: EmbeddedDSHRuntimeResources) throws -> Self {
    #if os(Windows)
      let executable = "provider/model-protocol.exe"
    #else
      let executable = "provider/model-protocol"
    #endif
    let paths = [
      "provider/community/host.js", executable, "provider/agent-connections/index.mjs",
      "provider/community/cli.mjs", "provider/community/catalog.json",
    ]
    let snapshots = try paths.map {
      try runtime.snapshotFile(relativePath: $0, requiresExecutable: $0 == executable)
    }
    return Self(
      root: runtime.root, node: URL(fileURLWithPath: runtime.node.canonicalPath),
      communityEntry: URL(fileURLWithPath: snapshots[0].canonicalPath),
      protocolExecutable: URL(fileURLWithPath: snapshots[protocolSnapshotIndex].canonicalPath),
      agentEditorEntry: URL(fileURLWithPath: snapshots[2].canonicalPath),
      installationEntry: URL(fileURLWithPath: snapshots[3].canonicalPath),
      catalog: URL(fileURLWithPath: snapshots[4].canonicalPath),
      runtime: runtime, snapshots: snapshots)
  }

  public func validateEntrypoints() throws {
    try runtime.validateEntrypoints()
    for (index, snapshot) in snapshots.enumerated() {
      try Self.verify(snapshot, requiresExecutable: index == Self.protocolSnapshotIndex)
    }
  }

  /// Re-checks only the model-protocol helper, for launches that run nothing else from the runtime.
  public func validateProtocolExecutable() throws {
    try Self.verify(snapshots[Self.protocolSnapshotIndex], requiresExecutable: true)
  }

  private static let protocolSnapshotIndex = 1

  private static func verify(_ snapshot: SecureFileArtifactSnapshot, requiresExecutable: Bool)
    throws
  {
    guard
      snapshot
        == (try SecureFileArtifactSnapshot.capture(
          at: snapshot.canonicalPath, requiresExecutable: requiresExecutable))
    else { throw ProviderRuntimeResourcesError.resourceChanged }
  }
}

public enum ProviderRuntimeResourcesError: Error, Sendable {
  case resourceChanged
}

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
    let runtime = try EmbeddedDSHRuntimeResources.load(root: root)
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
      protocolExecutable: URL(fileURLWithPath: snapshots[1].canonicalPath),
      agentEditorEntry: URL(fileURLWithPath: snapshots[2].canonicalPath),
      installationEntry: URL(fileURLWithPath: snapshots[3].canonicalPath),
      catalog: URL(fileURLWithPath: snapshots[4].canonicalPath),
      runtime: runtime, snapshots: snapshots)
  }

  public func validateEntrypoints() throws {
    try runtime.validateEntrypoints()
    for (index, snapshot) in snapshots.enumerated() {
      guard
        snapshot
          == (try SecureFileArtifactSnapshot.capture(
            at: snapshot.canonicalPath, requiresExecutable: index == 1))
      else { throw ProviderRuntimeResourcesError.resourceChanged }
    }
  }
}

public enum ProviderRuntimeResourcesError: Error, Sendable {
  case resourceChanged
}

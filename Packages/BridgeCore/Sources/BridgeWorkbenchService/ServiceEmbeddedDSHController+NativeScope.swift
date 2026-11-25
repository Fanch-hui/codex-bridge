import BridgeServiceCore
import Foundation

/// A session-ID map that bumps `revision` only when a value really changes, so caches derived
/// from it (the native scope) can tell whether they are still current.
struct NativeSessionMap: Sendable {
  private(set) var entries: [String: String] = [:]
  private(set) var revision: UInt64 = 0

  subscript(key: String) -> String? {
    get { entries[key] }
    set {
      guard entries[key] != newValue else { return }
      entries[key] = newValue
      revision &+= 1
    }
  }
}

/// The map revisions and write counter of the last completed full conversation-mapping load.
struct ConversationMappingsLoad: Sendable {
  let projectsRevision: UInt64
  let logicalIDsRevision: UInt64
  let writes: UInt64
  let expiresAt: ContinuousClock.Instant
}

/// The scope derived for one exact set of inputs. It is a pure function of the validated project
/// set and the two session maps, so reuse never hides a project or identity change.
struct NativeScopeMemo: Sendable {
  let projectIDs: Set<String>
  let projectPaths: Set<String>
  let projectsRevision: UInt64
  let logicalIDsRevision: UInt64
  let scope: NativeClientScope
}

extension ServiceEmbeddedDSHController {
  /// Upper bound on how long a full conversation re-read may be skipped when nothing changed.
  private static let conversationMappingLifetime: Duration = .seconds(2)

  /// Call after every write to the workbench conversation tables.
  func noteConversationWrite() {
    conversationWrites &+= 1
  }

  /// Conversation mappings only grow and every conversation write happens in this controller, so
  /// a full table scan is needed only after a write or once the safety lifetime has passed.
  func refreshConversationMappings() async throws {
    let writes = conversationWrites
    let now = ContinuousClock.now
    if let loaded = loadedConversationMappings,
      loaded.projectsRevision == sessionProjects.revision,
      loaded.logicalIDsRevision == nativeLogicalIDs.revision,
      loaded.writes == writes,
      now < loaded.expiresAt
    {
      return
    }
    try await loadConversationMappings()
    loadedConversationMappings = ConversationMappingsLoad(
      projectsRevision: sessionProjects.revision,
      logicalIDsRevision: nativeLogicalIDs.revision,
      writes: writes,
      expiresAt: now.advanced(by: Self.conversationMappingLifetime)
    )
  }

  /// Registry and root identities are re-validated on every call, so a removed project or a
  /// replaced directory leaves the scope immediately. Only the conversation mappings (a full table
  /// scan) and the derivation from them are reused, and only while their inputs are unchanged.
  func currentNativeScope() async throws -> NativeClientScope {
    let registered = try await projects.projects()
    var projectIDs: Set<String> = []
    var projectPaths: Set<String> = []
    for project in registered {
      do { try project.root.validateCurrentIdentity() } catch { continue }
      projectIDs.insert(project.id.rawValue)
      projectPaths.insert(project.root.canonicalPath)
    }
    try await refreshConversationMappings()
    if let memo = nativeScopeMemo, memo.projectIDs == projectIDs,
      memo.projectPaths == projectPaths,
      memo.projectsRevision == sessionProjects.revision,
      memo.logicalIDsRevision == nativeLogicalIDs.revision
    {
      return memo.scope
    }
    var paths = projectPaths
    var sessionIDs = sessionProjects.entries.compactMap { sessionID, projectID in
      projectIDs.contains(projectID) ? sessionID : nil
    }.sorted()
    let chatIDs = nativeLogicalIDs.entries.keys.filter { sessionProjects[$0] == nil }
    if !chatIDs.isEmpty { paths.insert(dataRoot.appendingPathComponent("WorkbenchChat").path) }
    sessionIDs.append(contentsOf: chatIDs)
    let scope = NativeClientScope(
      sessionIDs: Array(Set(sessionIDs)).sorted(), workspacePaths: paths.sorted())
    nativeScopeMemo = NativeScopeMemo(
      projectIDs: projectIDs, projectPaths: projectPaths,
      projectsRevision: sessionProjects.revision,
      logicalIDsRevision: nativeLogicalIDs.revision, scope: scope)
    return scope
  }
}

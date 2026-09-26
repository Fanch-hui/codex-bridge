import BridgeAgentCore
import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func serviceNativeSessionDirectory(
    _ request: MCPNativeSessionDirectoryRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPNativeSessionDirectoryResponse {
    try Self.checkDeadline(deadline)
    let project = try await readableProject(request.projectID)
    let registry = try requiredAgentRegistry()
    let installationID = AgentInstallationID(rawValue: request.installationID)
    let (manager, installation, record) = try await registry.nativeSessionDirectoryManager(
      installationID: installationID)
    let scope = try await nativeSessionScope(project: project, installation: record)
    let page = try AgentNativeSessionPageRequest(offset: request.offset, limit: request.limit)

    do {
      switch request.operation {
      case .list:
        let result = try await manager.listNativeSessions(
          scope: scope, installation: installation, page: page)
        return MCPNativeSessionDirectoryResponse(page: result)
      case .read:
        let sessionID = try requiredSessionID(request)
        let result = try await manager.readNativeSession(
          sessionID: sessionID, scope: scope, installation: installation, page: page)
        return MCPNativeSessionDirectoryResponse(transcript: result)
      case .index:
        let sessionID = try requiredSessionID(request)
        try await requireIdleNativeSession(scope, sessionID: sessionID)
        let receipt = try await manager.indexNativeSession(
          sessionID: sessionID, scope: scope, installation: installation)
        return MCPNativeSessionDirectoryResponse(receipt: receipt)
      case .rename:
        let sessionID = try requiredSessionID(request)
        let title = try requiredNativeSessionTitle(request.title)
        try await requireIdleNativeSession(scope, sessionID: sessionID)
        let result = try await manager.renameNativeSession(
          sessionID: sessionID, title: title, scope: scope, installation: installation)
        return MCPNativeSessionDirectoryResponse(summary: result)
      case .delete:
        guard request.confirmed else { throw BridgeMCPQueryError.contractRejected }
        let sessionID = try requiredSessionID(request)
        try await requireIdleNativeSession(scope, sessionID: sessionID)
        try await manager.deleteNativeSession(
          sessionID: sessionID, scope: scope, installation: installation)
        return MCPNativeSessionDirectoryResponse(deleted: true)
      }
    } catch let error as AgentNativeSessionDirectoryError {
      switch error {
      case .invalidRequest: throw BridgeMCPQueryError.contractRejected
      case .unavailable, .runtimeFailure: throw BridgeMCPQueryError.unavailable
      case .sessionNotFound: throw BridgeMCPQueryError.taskNotFound
      case .activeSession: throw BridgeMCPQueryError.invalidTaskState
      case .scopeMismatch: throw BridgeMCPQueryError.pathDenied
      }
    }
  }

  func nativeSessionScope(
    project: ServiceProjectRecord,
    installation: ServiceAgentInstallationRecord
  ) async throws -> AgentNativeSessionDirectoryScope {
    let region: String?
    if installation.providerID == .qoder {
      guard let distribution = try await qoderDistribution(for: installation) else {
        throw BridgeMCPQueryError.unavailable
      }
      region = distribution.rawValue
    } else {
      region = nil
    }
    return try AgentNativeSessionDirectoryScope(
      providerID: installation.providerID,
      installationID: installation.id,
      projectID: project.id.rawValue,
      projectRoot: project.root.canonicalPath,
      region: region)
  }

  private func requireIdleNativeSession(
    _ scope: AgentNativeSessionDirectoryScope,
    sessionID: String
  ) async throws {
    let active = try await tasks.nonterminalTasks().contains { task in
      task.projectID.rawValue == scope.projectID
        && task.providerID == scope.providerID.rawValue
        && task.installationID == scope.installationID.rawValue
        && ((task.state.providerSessionID ?? task.requestedThreadID) == sessionID
          || (task.state.providerSessionID == nil && task.requestedThreadID == nil))
    }
    guard !active else { throw AgentNativeSessionDirectoryError.activeSession }
  }

  private func requiredSessionID(_ request: MCPNativeSessionDirectoryRequest) throws -> String {
    guard let sessionID = request.sessionID,
      !sessionID.isEmpty,
      sessionID.utf8.count <= 256,
      sessionID.rangeOfCharacter(from: .controlCharacters) == nil
    else { throw BridgeMCPQueryError.contractRejected }
    return sessionID
  }

  private func requiredNativeSessionTitle(_ value: String?) throws -> String {
    guard let value else { throw BridgeMCPQueryError.contractRejected }
    let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, title.utf8.count <= 4_096,
      title.rangeOfCharacter(from: .controlCharacters) == nil
    else { throw BridgeMCPQueryError.contractRejected }
    return title
  }
}

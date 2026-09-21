import BridgeCodexService
import BridgeDomain
import BridgeFiles
import BridgeMCP
import BridgeProjects
import BridgeSecurity
import BridgeServiceCore
import BridgeSkills
import Foundation

extension BridgeServiceApplication {
  func managedProject(_ rawID: String) async throws -> ServiceProjectRecord {
    guard !rawID.isEmpty, rawID.utf8.count <= 128, !rawID.contains("\0") else {
      throw BridgeMCPQueryError.projectNotFound
    }
    let id = ProjectID(rawValue: rawID)
    guard let project = try await projects.project(id: id) else {
      throw BridgeMCPQueryError.projectNotFound
    }
    do {
      try project.root.validateCurrentIdentity()
    } catch {
      throw BridgeMCPQueryError.unavailable
    }
    return project
  }

  func readableProject(_ rawID: String) async throws -> ServiceProjectRecord {
    let project = try await managedProject(rawID)
    guard project.accessPolicy.read == .allowed else {
      throw BridgeMCPQueryError.pathDenied
    }
    return project
  }

  static func permissionMode(
    _ rawValue: String?,
    project: ServiceProjectRecord,
    defaultMode: ServicePermissionMode? = nil
  ) throws -> ServicePermissionMode {
    if let rawValue {
      guard let mode = ServicePermissionMode(rawValue: rawValue) else {
        throw BridgeMCPQueryError.contractRejected
      }
      if mode == .workspaceWrite, project.accessPolicy.write == .denied {
        throw BridgeMCPQueryError.contractRejected
      }
      return mode
    }
    guard let defaultMode else {
      return project.accessPolicy.write == .denied ? .readOnly : .workspaceWrite
    }
    if defaultMode == .workspaceWrite, project.accessPolicy.write == .denied {
      return .readOnly
    }
    return defaultMode
  }

  static func permissionModeRequest(
    _ rawValue: String?,
    override: Bool?,
    requirePermissionModeOverride: Bool
  ) throws -> String? {
    guard let rawValue else { return nil }
    guard let mode = ServicePermissionMode(rawValue: rawValue) else {
      throw BridgeMCPQueryError.contractRejected
    }
    if requirePermissionModeOverride, override != true {
      return nil
    }
    return mode.rawValue
  }

  static func prompt(_ prompt: String, acceptanceCriteria: [String]) -> String {
    guard !acceptanceCriteria.isEmpty else { return prompt }
    let lines = acceptanceCriteria.enumerated().map { index, value in
      "\(index + 1). \(value.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
    return prompt + "\n\nAcceptance criteria:\n" + lines.joined(separator: "\n")
  }

  static func projectSummary(_ source: ServiceProjectRecord, gitState: String? = nil)
    -> MCPProjectSummary
  {
    MCPProjectSummary(
      projectID: source.id.rawValue,
      name: safe(source.name, maximum: 1_024),
      capabilities: capabilities(source.accessPolicy),
      gitState: gitState
    )
  }

  static func projectDetail(_ project: ServiceProjectRecord, gitState: String? = nil)
    -> MCPProjectDetail
  {
    MCPProjectDetail(
      projectID: project.id.rawValue,
      name: safe(project.name, maximum: 1_024),
      capabilities: capabilities(project.accessPolicy),
      gitState: gitState,
      verificationCommands: [],
      directWorkspace: MCPDirectWorkspace(
        fileWritePermission: project.accessPolicy.write.rawValue,
        commandMode: project.directCommandMode.rawValue,
        commands: project.workspaceCommands.map(Self.projectCommand),
        commandBlacklist: project.commandBlacklist.map(Self.blacklistRule)
      )
    )
  }

  static func sortedProjects(_ projects: [ServiceProjectRecord]) -> [ServiceProjectRecord] {
    projects.sorted {
      let order = $0.name.localizedCaseInsensitiveCompare($1.name)
      return order == .orderedSame
        ? $0.id.rawValue < $1.id.rawValue
        : order == .orderedAscending
    }
  }

  static func capabilities(_ policy: ProjectAccessPolicy) -> MCPProjectCapabilities {
    MCPProjectCapabilities(
      read: policy.read.rawValue,
      write: policy.write.rawValue,
      network: policy.network.rawValue
    )
  }

  static func projectCommand(_ command: ServiceWorkspaceCommand) -> MCPProjectCommand {
    MCPProjectCommand(
      commandID: command.id,
      name: Self.safe(command.name, maximum: 256),
      executable: Self.safe(command.executable, maximum: 4_096),
      arguments: command.arguments.map { Self.safe($0, maximum: 4_096) },
      workingDirectory: command.workingDirectory.map { Self.safe($0, maximum: 1_024) },
      requiresNetwork: command.requiresNetwork,
      risk: command.risk.rawValue
    )
  }

  static func blacklistRule(_ rule: ServiceCommandBlacklistRule) -> MCPCommandBlacklistRule {
    MCPCommandBlacklistRule(
      ruleID: Self.safe(rule.id, maximum: 128),
      executable: rule.executable.map { Self.safe($0, maximum: 4_096) },
      pattern: rule.pattern.map { Self.safe($0, maximum: 4_096) },
      arguments: rule.arguments
    )
  }

  static func executionState(_ tasks: [ServiceTaskRecord]) -> String {
    if tasks.contains(where: { $0.state.status == .unknown }) { return "unknown" }
    if tasks.contains(where: {
      [.starting, .running, .waitingForCodexApproval].contains($0.state.status)
    }) {
      return "active"
    }
    if tasks.contains(where: {
      $0.isQueued || $0.state.status == .awaitingLocalApproval
    }) {
      return "pending"
    }
    return "idle"
  }

  static func supervisorState(_ tasks: [ServiceTaskRecord]) -> String {
    let activeTasks = tasks.filter { !$0.state.status.isTerminal }
    if activeTasks.contains(where: { $0.state.supervisorStatus == .degraded }) {
      return "degraded"
    }
    if activeTasks.contains(where: {
      [.starting, .running].contains($0.state.supervisorStatus)
    }) {
      return "active"
    }
    return "idle"
  }

  static func decodeOffset(_ cursor: String?, maximum: Int) throws -> Int {
    guard let cursor else { return 0 }
    let parts = cursor.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0] == "v1", let value = Int(parts[1]),
      value >= 0, value <= maximum
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    return value
  }

  static func safe(_ value: String, maximum: Int) -> String {
    OutboundContentSecurity.redacted(value, maximumUTF8Bytes: maximum)
  }

  static func checkDeadline(_ deadline: ContinuousClock.Instant) throws {
    guard ContinuousClock.now < deadline else { throw BridgeMCPQueryError.timeout }
  }
}

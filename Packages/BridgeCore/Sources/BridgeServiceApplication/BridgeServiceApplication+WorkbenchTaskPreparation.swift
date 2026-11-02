import BridgeAgentCore
import BridgeDomain
import BridgeMCP
import BridgeSecurity
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func prepareWorkbenchTaskOperation(kind: String, inputJSON: String) async throws -> String
  {
    let request = try WorkbenchTaskOperationCodec.decode(
      WorkbenchTaskOperationInput.self, inputJSON)
    let binding = try await workbenchTaskBinding(kind: kind, request: request)
    return try WorkbenchTaskOperationCodec.encode(
      PreparedWorkbenchTaskOperation(request: request, binding: binding))
  }

  func workbenchTaskBinding(
    kind: String, request: WorkbenchTaskOperationInput
  ) async throws -> WorkbenchTaskOperationBinding {
    guard ["workbench.resume", "workbench.steer", "handoff.submit"].contains(kind) else {
      throw BridgeMCPQueryError.contractRejected
    }
    guard let task = try await tasks.task(id: TaskID(rawValue: request.taskID)) else {
      throw BridgeMCPQueryError.taskNotFound
    }
    let project = try await readableProject(task.projectID.rawValue)
    let sessionID =
      task.providerID == serviceCodexProviderID
      ? (task.state.codexThreadID ?? task.requestedThreadID)
      : (task.state.providerSessionID ?? task.requestedThreadID)
    let controlID =
      task.providerID == serviceCodexProviderID
      ? task.state.codexTurnID : task.state.providerRunID
    try Self.validateWorkbenchTaskRequest(
      kind: kind, request: request, task: task,
      sessionID: sessionID, controlID: controlID)

    let attachments =
      kind == "workbench.resume"
      ? try Self.captureWorkbenchTaskAttachments(request.attachmentPaths ?? [], project: project)
      : []
    let runtimeBinding = kind == "handoff.submit" ? nil : try await runtimeBindingForTask(task)
    let artifactDigest =
      kind == "handoff.submit" ? nil : try await workbenchTaskArtifactDigest(task)
    var handoffFingerprint: String?
    var handoffSourceRevision: String?
    if kind == "handoff.submit" {
      guard let id = request.handoffID, let providerID = request.providerID,
        let revision = request.revision, let record = try await tasks.handoff(id: id),
        record.packet.sourceTaskID == task.id.rawValue,
        record.preview.providerID == providerID, record.preview.revision == revision,
        record.preview.ready
      else { throw TaskHandoffError.rejected("请先确认当前交接预览。") }
      handoffFingerprint = record.targetFingerprint
      handoffSourceRevision = record.packet.sourceRevision
    }
    return WorkbenchTaskOperationBinding(
      taskID: task.id.rawValue, projectID: task.projectID.rawValue, providerID: task.providerID,
      installationID: task.installationID, sessionID: sessionID,
      controlID: kind == "workbench.steer" ? controlID : nil,
      executionModel: task.executionModel, executionEffort: task.executionEffort,
      permissionMode: task.permissionMode, accessMode: task.accessMode, fastMode: task.fastMode,
      projectRoot: project.root, artifactDigest: artifactDigest,
      runtimeMode: runtimeBinding?.connectionMode, runtimeProfileID: runtimeBinding?.profileID,
      attachments: attachments, handoffFingerprint: handoffFingerprint,
      handoffSourceRevision: handoffSourceRevision)
  }

  private static func validateWorkbenchTaskRequest(
    kind: String, request: WorkbenchTaskOperationInput, task: ServiceTaskRecord,
    sessionID: String?, controlID: String?
  ) throws {
    guard !request.taskID.isEmpty, request.taskID.utf8.count <= 128,
      request.input.map({ $0.utf8.count <= 32 * 1_024 && !$0.contains("\0") }) ?? true
    else { throw BridgeMCPQueryError.contractRejected }
    switch kind {
    case "workbench.steer":
      guard !task.isQueued,
        task.state.status == .running
          || (task.providerID != serviceCodexProviderID
            && task.state.status == .waitingForCodexApproval),
        controlID != nil, let input = request.input,
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw BridgeMCPQueryError.turnMismatch }
    case "workbench.resume":
      guard task.state.status.isTerminal, sessionID != nil else {
        throw BridgeMCPQueryError.invalidTaskState
      }
    case "handoff.submit":
      guard task.state.status.isTerminal else { throw BridgeMCPQueryError.invalidTaskState }
    default: throw BridgeMCPQueryError.contractRejected
    }
  }

  private static func captureWorkbenchTaskAttachments(
    _ paths: [String], project: ServiceProjectRecord
  ) throws -> [AgentImageAttachment] {
    guard !paths.isEmpty else { return [] }
    let root = try RegisteredRoot(
      capturing: URL(fileURLWithPath: project.root.canonicalPath, isDirectory: true))
    guard root.canonicalPath == project.root.canonicalPath,
      root.identity.device == project.root.device, root.identity.inode == project.root.inode
    else { throw BridgeMCPQueryError.contractRejected }
    return try SecureProjectImageReader.capture(relativePaths: paths, through: root).map(
      \.attachment)
  }

  private func workbenchTaskArtifactDigest(_ task: ServiceTaskRecord) async throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if task.providerID == serviceCodexProviderID {
      let artifacts = try await coordinator.codexInstallationArtifacts()
      return Self.handoffDigest([try encoder.encode(artifacts).base64EncodedString()])
    }
    guard let installationID = task.installationID else { throw BridgeMCPQueryError.unavailable }
    let installation = try await requiredAgentRegistry().validateForExecution(
      installationID: AgentInstallationID(rawValue: installationID))
    guard installation.providerID.rawValue == task.providerID else {
      throw BridgeMCPQueryError.unavailable
    }
    let artifacts = installation.artifacts.map {
      WorkbenchInstallationArtifact(role: $0.role.rawValue, identity: $0.identity)
    }.sorted { $0.role < $1.role }
    let runtimeArtifacts = installation.runtimeArtifacts.sorted {
      $0.canonicalPath < $1.canonicalPath
    }
    let capabilities = installation.capabilities
    return Self.handoffDigest([
      installation.id.rawValue, installation.providerID.rawValue, installation.executablePath,
      try encoder.encode(installation.executableIdentity).base64EncodedString(),
      installation.version ?? "", installation.protocolRevision ?? "",
      String(installation.adapterRevision),
      try encoder.encode(installation.trustProfile).base64EncodedString(),
      try encoder.encode(installation.securityProfileID).base64EncodedString(),
      capabilities.advertised.map(\.rawValue).sorted().joined(separator: ","),
      capabilities.observed.map(\.rawValue).sorted().joined(separator: ","),
      capabilities.enforced.map(\.rawValue).sorted().joined(separator: ","),
      try encoder.encode(artifacts).base64EncodedString(),
      try encoder.encode(runtimeArtifacts).base64EncodedString(),
    ])
  }
}

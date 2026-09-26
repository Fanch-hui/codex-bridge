import BridgeAgentCore
import BridgeCodexService
import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public struct PendingTaskStartApproval: Equatable, Sendable {
    public let approvalID: String
    public let taskID: String
    public let projectID: String
    public let clientID: String
    public let prompt: String
    public let providerID: String
    public let permissionMode: String
    public let networkAllowed: Bool
    public let oneTimeToolAutoApprovalAvailable: Bool

    public var providerDisplayName: String {
      ServiceAgentProviderPolicyRegistry.displayName(
        for: AgentProviderID(rawValue: providerID)
      )
    }

    public init(
      task: ServiceTaskRecord,
      oneTimeToolAutoApprovalAvailable: Bool = false
    ) {
      approvalID = Self.approvalID(for: task.id)
      taskID = task.id.rawValue
      projectID = task.projectID.rawValue
      clientID = task.source == .chatGPT ? MCPClientID.chatGPT.rawValue : task.sourceClientID
      prompt = task.prompt
      providerID = task.providerID
      permissionMode = task.permissionMode.rawValue
      networkAllowed = task.networkAllowed
      self.oneTimeToolAutoApprovalAvailable = oneTimeToolAutoApprovalAvailable
    }

    public static func approvalID(for taskID: TaskID) -> String {
      "bridge-task-start:\(taskID.rawValue)"
    }
  }

  public func pendingTaskStartApprovals(taskID: TaskID? = nil) async throws
    -> [PendingTaskStartApproval]
  {
    let taskList: [ServiceTaskRecord]
    if let taskID {
      taskList = try await tasks.task(id: taskID).map { [$0] } ?? []
    } else {
      taskList = try await tasks.tasks(limit: 500)
    }
    var result: [PendingTaskStartApproval] = []
    for task in taskList {
      guard !task.isQueued,
        task.state.status == .awaitingLocalApproval,
        task.requiresLocalStartApproval
      else {
        continue
      }
      let policy = ServiceAgentProviderPolicyRegistry.policy(for: task.providerID)
      let project = try await projects.project(id: task.projectID)
      let canGrantOneTimeAccess =
        policy?.supportsOneTimeToolAutoApproval == true
        && project?.accessPolicy.network != .denied
        && (task.permissionMode != .workspaceWrite || project?.accessPolicy.write != .denied)
      result.append(
        PendingTaskStartApproval(
          task: task,
          oneTimeToolAutoApprovalAvailable: canGrantOneTimeAccess
        )
      )
    }
    return result
  }

  public func resolveTaskStartApproval(
    taskID: TaskID,
    approvalID: String,
    approved: Bool,
    oneTimeToolAutoApproval: Bool = false,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    guard approvalID == PendingTaskStartApproval.approvalID(for: taskID),
      let task = try await tasks.task(id: taskID),
      !task.isQueued,
      task.state.status == .awaitingLocalApproval,
      task.requiresLocalStartApproval
    else {
      throw BridgeMCPQueryError.approvalExpired
    }
    if approved {
      let authorization = try await taskExecutionAuthorization(
        for: task,
        oneTimeToolAutoApproval: oneTimeToolAutoApproval
      )
      try await approveAndStartTask(taskID, authorization: authorization)
    } else {
      do {
        _ = try await tasks.denyStart(taskID: taskID)
      } catch ServiceStoreError.invalidTaskTransition {
        throw BridgeMCPQueryError.approvalExpired
      } catch let storeError as ServiceStoreError {
        throw Self.publicStoreError(storeError)
      } catch {
        throw error
      }
    }
  }

  func submitTaskWithAdmission(
    _ request: ServiceTaskRequest,
    projectID: ProjectID,
    handoffID: String? = nil
  ) async throws -> ServiceTaskCreationResult {
    // Read-only submissions never occupy the project write slot, so they do
    // not take the Codex admission token.
    if request.permissionMode == .readOnly {
      do {
        return try await tasks.submit(request, handoffID: handoffID)
      } catch let storeError as ServiceStoreError {
        throw Self.publicStoreError(storeError)
      }
    }
    let wantsQueue = request.queueIfBusy
    if wantsQueue {
      let activeWriteTask = try await tasks.activeWriteTask(projectID: projectID)
      let workspaceBusy = try await workspaceGate.workspaceBusyDetail(projectID: projectID)
      if activeWriteTask != nil || workspaceBusy != nil {
        return try await tasks.submit(request, queued: true, handoffID: handoffID)
      }
    }
    let admissionToken: String
    do {
      admissionToken = try await workspaceGate.beginCodexAdmission(projectID: projectID)
    } catch {
      if wantsQueue {
        return try await tasks.submit(request, queued: true, handoffID: handoffID)
      }
      throw Self.publicWorkspaceBusyError(error)
    }
    do {
      let result: ServiceTaskCreationResult
      do {
        result = try await tasks.submit(request, handoffID: handoffID)
      } catch ServiceStoreError.activeWriteTaskExists where wantsQueue {
        await workspaceGate.endCodexAdmission(projectID: projectID, token: admissionToken)
        return try await tasks.submit(request, queued: true, handoffID: handoffID)
      }
      await workspaceGate.endCodexAdmission(projectID: projectID, token: admissionToken)
      return result
    } catch {
      await workspaceGate.endCodexAdmission(projectID: projectID, token: admissionToken)
      if let storeError = error as? ServiceStoreError {
        throw Self.publicStoreError(storeError)
      }
      throw error
    }
  }

  func approveAndStartTask(
    _ taskID: TaskID,
    automatically: Bool = false,
    authorization: ServiceTaskExecutionAuthorization? = nil,
    summary: String? = nil
  ) async throws {
    let started: ServiceTaskRecord
    do {
      started = try await tasks.approveAndBegin(
        taskID: taskID,
        summary: summary
          ?? (authorization != nil
            ? "The local user approved this provider invocation with one-time tool and network access."
            : automatically
              ? "The configured local policy automatically approved this provider invocation."
              : "The local user approved this provider invocation."),
        authorization: authorization
      )
    } catch ServiceStoreError.invalidTaskTransition {
      throw BridgeMCPQueryError.approvalExpired
    } catch let storeError as ServiceStoreError {
      throw Self.publicStoreError(storeError)
    } catch {
      throw error
    }
    do {
      try await coordinator.start(taskID: started.id)
    } catch {
      throw Self.publicExecutionError(error)
    }
  }

  private func taskExecutionAuthorization(
    for task: ServiceTaskRecord,
    oneTimeToolAutoApproval: Bool
  ) async throws -> ServiceTaskExecutionAuthorization? {
    guard oneTimeToolAutoApproval else { return nil }
    guard
      ServiceAgentProviderPolicyRegistry.policy(for: task.providerID)?
        .supportsOneTimeToolAutoApproval == true,
      let installationID = task.installationID,
      let registry = agentRegistry,
      let project = try await projects.project(id: task.projectID),
      project.accessPolicy.network != .denied,
      task.permissionMode != .workspaceWrite || project.accessPolicy.write != .denied
    else {
      throw BridgeMCPQueryError.approvalDenied
    }
    let installation = try await registry.validateForExecution(
      installationID: AgentInstallationID(rawValue: installationID)
    )
    guard installation.providerID.rawValue == task.providerID else {
      throw BridgeMCPQueryError.approvalDenied
    }
    return ServiceTaskExecutionAuthorization(
      accessMode: .fullAccess,
      networkAllowed: true
    )
  }

  public func pendingCodexApprovals(taskID: TaskID? = nil) async
    -> [ExecutionApprovalRequest]
  {
    await coordinator.pendingApprovals(taskID: taskID)
  }

  public func resolveCodexApproval(
    taskID: TaskID,
    approvalID: String,
    decision: LocalApprovalDecision,
    answers: [String: [String]]? = nil
  ) async throws {
    try await coordinator.resolveApproval(
      taskID: taskID,
      approvalID: approvalID,
      decision: decision,
      answers: answers
    )
  }

  public func resolveUserInput(
    taskID: TaskID,
    inputID: String,
    answers: [String: [String]]?,
    cancelled: Bool
  ) async throws {
    guard cancelled ? answers == nil : answers != nil else {
      throw ExecutionServiceError.invalidRequest("userInput.response")
    }
    try await coordinator.resolveUserInput(
      taskID: taskID,
      inputID: inputID,
      response: cancelled ? .cancelled : .answers(answers ?? [:])
    )
  }
}

import BridgeACP
import BridgeAgentCore
import BridgeCodexService
import BridgeDomain
import BridgeEmbeddedDSH
import BridgeServiceCore
import Foundation

/// Providers listed in `AgentToolWriteGate.supportedProviders` hold the project write lease only
/// while a writing tool runs. The workbench engine and this controller derive the scope from the
/// same rule, so a task is never both gated per tool and holding a task-long lease.
extension ServiceEmbeddedDSHController: ServiceToolWriteGateProviding {
  static func toolWriteScope(providerID: String) -> String {
    AgentToolWriteGate.supportedProviders.contains(AgentProviderID(rawValue: providerID))
      ? "tool" : "task"
  }

  func subagentProviderID(installationID: String) async throws -> String {
    if installationID == "codex" { return "codex" }
    guard let agent = try await application.serviceAgent(installationID: installationID),
      agent.enabled, agent.taskSubmissionEnabled
    else { throw ServiceStoreError.invalidArgument("embedded_dsh.installation") }
    return agent.providerID
  }

  func subagentWriteScope(installationID: String?) async throws -> String {
    guard let installationID else { return "task" }
    return Self.toolWriteScope(
      providerID: try await subagentProviderID(installationID: installationID))
  }

  public func toolWriteGate(
    for task: ServiceTaskRecord, identity: EmbeddedDSHSubagentIdentity
  ) async throws -> AgentToolWriteGate? {
    guard task.permissionMode == .full,
      Self.toolWriteScope(providerID: task.providerID) == "tool",
      try await workspaceMode(rootID: identity.parentSessionID, childID: identity.childID)
        == "shared"
    else { return nil }
    return await toolWriteLeases.makeGate(
      taskID: task.id, rootID: identity.parentSessionID, childID: identity.childID,
      engine: toolWriteEngine())
  }

  public func releaseToolWriteLeases(taskID: TaskID) async {
    await toolWriteLeases.releaseAll(taskID: taskID)
  }

  private func toolWriteEngine() -> EmbeddedDSHToolWriteEngine {
    EmbeddedDSHToolWriteEngine(
      acquire: { [weak self] rootID, owner in
        guard let self else { throw CancellationError() }
        return try await self.acquireToolWriteLease(rootID: rootID, owner: owner)
      },
      release: { [weak self] rootID, owner, token in
        try await self?.runToolWriteLeaseAction(
          "workspace.release", rootID: rootID, owner: owner, token: token)
      },
      cancel: { [weak self] rootID, owner in
        try await self?.runToolWriteLeaseAction("workspace.cancel", rootID: rootID, owner: owner)
      })
  }

  /// Waits for the lease without taking a runtime admission slot or timing out. The engine does
  /// not hear about a cancelled wait, so the caller revokes the owner afterwards.
  private func acquireToolWriteLease(rootID: String, owner: String) async throws -> String {
    let lease = try await invoke(
      action: "workspace.acquire",
      payload: .object([
        "sessionId": .string(rootID), "ownerId": .string(owner), "wait": .bool(true),
      ]), waitsForWriter: true)
    guard lease["acquired"]?.boolValue == true, let token = lease["token"]?.stringValue else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_lease")
    }
    return token
  }

  /// Runs detached so that a cancelled task still frees its lease. A stopped engine has already
  /// dropped every lease, so that outcome counts as released.
  private func runToolWriteLeaseAction(
    _ action: String, rootID: String, owner: String, token: String? = nil
  ) async throws {
    guard !isShuttingDown, let runtime else { return }
    var payload: [String: ACPJSONValue] = ["sessionId": .string(rootID), "ownerId": .string(owner)]
    if let token { payload["token"] = .string(token) }
    let call = Task.detached { [payload] in
      try await runtime.call(action: action, payload: .object(payload))
    }
    do {
      _ = try await call.value
    } catch let error as EmbeddedDSHRuntimeError where error.hostIsGone {
      return
    } catch is CancellationError {
      return
    }
  }
}

extension EmbeddedDSHRuntimeError {
  fileprivate var hostIsGone: Bool {
    switch self {
    case .stopped, .transportClosed, .processExited: true
    default: false
    }
  }
}

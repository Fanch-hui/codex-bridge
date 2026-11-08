import BridgeACP
import BridgeAgentCore
import BridgeDomain
import BridgeEmbeddedDSH
import BridgeProcess
import BridgeSecurity
import BridgeServiceCore
import Foundation

extension ServiceEmbeddedDSHController {
  private struct PersistedWorkspaceWriter: Decodable {
    let rootID: String
    let ownerID: String
  }

  func validateWorkspaceWriteRecovery(projectID: ProjectID) async throws {
    let writers = try persistedWorkspaceWriters()
    for rootID in Set(writers.filter { $0.ownerID.hasPrefix("tool:") }.map(\.rootID)) {
      if try await storedProjectID(for: rootID) == projectID.rawValue {
        throw ServiceStoreError.invalidArgument("workbench.workspace_recovery_required")
      }
    }
  }

  func startNativeWriteRecovery() async {
    guard nativeWriteRecoveryTask == nil else { return }
    do {
      try await requireWorkbenchEnabled()
    } catch WorkbenchAvailabilityError.disabled {
      return
    } catch WorkbenchAvailabilityError.busy {
      return
    } catch {
      await receive(
        EmbeddedDSHEvent(
          type: "workspace.recovery.failed",
          payload: .object(["message": .string("工作区恢复尚未完成，请在工作台检查状态。")])))
      return
    }
    guard nativeWriteRecoveryTask == nil else { return }
    nativeWriteRecoveryTask = Task {
      defer { self.nativeWriteRecoveryTask = nil }
      do {
        guard try self.hasPersistedNativeWorkspaceWriters() else { return }
        _ = try await self.invoke(action: "workspace.recovery.check", payload: .object([:]))
        try await self.reconcileNativeWorkspaceRecovery()
      } catch is CancellationError {
        return
      } catch WorkbenchAvailabilityError.disabled {
        return
      } catch WorkbenchAvailabilityError.busy {
        return
      } catch {
        await self.receive(
          EmbeddedDSHEvent(
            type: "workspace.recovery.failed",
            payload: .object(["message": .string("工作区恢复尚未完成，请在工作台检查状态。")]))
        )
      }
    }
  }

  func hasPersistedNativeWorkspaceWriters() throws -> Bool {
    try persistedWorkspaceWriters().contains { $0.ownerID.hasPrefix("tool:") }
  }

  private func persistedWorkspaceWriters() throws -> [PersistedWorkspaceWriter] {
    let file = dataRoot.appendingPathComponent("bridge-workspace-writes.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    let metadata = try FileSystemEntryMetadata(at: file)
    guard metadata.isRegularFile, !metadata.isSymbolicLink,
      let size = metadata.fileSize, size <= 4 * 1_024 * 1_024
    else { throw ServiceStoreError.invalidArgument("workbench.workspace_recovery") }
    let writers = try JSONDecoder().decode(
      [PersistedWorkspaceWriter].self, from: Data(contentsOf: file))
    guard writers.count <= 4_096 else {
      throw ServiceStoreError.invalidArgument("workbench.workspace_recovery")
    }
    return writers
  }

  func recoverExecutions() async throws {
    let executions = try await application.embeddedDSHExecutions()
    for execution in executions {
      let children = try await application.embeddedDSHSubagents(
        parentSessionID: execution.sessionID)
      for child in children where child.currentStatus == .unknown {
        do {
          try await recoverChild(child)
        } catch {
          await receive(
            EmbeddedDSHEvent(
              sessionID: execution.sessionID, type: "recovery.pending",
              payload: .object([
                "childID": .string(child.childID),
                "message": .string("原 Agent 执行尚待核对，请恢复连接后重试。"),
              ])))
        }
      }
      if execution.rootActive {
        do {
          try await validateWorkspaceWriteRecovery(projectID: execution.projectID)
        } catch {
          await receive(
            EmbeddedDSHEvent(
              sessionID: execution.sessionID, type: "recovery.pending",
              payload: .object([
                "message": .string("原会话的后台写入进程尚待核对，项目写入保持占用。")
              ])))
          continue
        }
        try await application.finishEmbeddedDSHExecution(
          sessionID: execution.sessionID, projectID: execution.projectID)
      }
    }
    Task { await self.retryPendingWorkspaces() }
  }

  func recoverChild(_ child: EmbeddedDSHSubagentBinding) async throws {
    guard child.currentStatus == .unknown, let taskID = child.currentTaskID else { return }
    if child.providerID == AgentProviderID.deepSeekHarnessDesktop.rawValue {
      guard let outcome = try await externalChildRecovery(child) else {
        throw EmbeddedDSHRecoveryError.pendingProcessReconciliation(taskID: taskID)
      }
      _ = try await application.reconcileEmbeddedDSHSubagent(
        parentSessionID: child.parentSessionID, childID: child.childID,
        taskID: taskID, outcome: outcome)
      return
    }
    let scope = try ManagedProcessOwnershipScope(
      directory: dataRoot.appendingPathComponent("AgentProcesses", isDirectory: true),
      ownerID: taskID.rawValue)
    guard await Task.detached(priority: .utility, operation: { scope.recover() }).value else {
      throw EmbeddedDSHRecoveryError.pendingProcessReconciliation(taskID: taskID)
    }
    await toolWriteLeases.releaseAll(taskID: taskID)
    _ = try await application.confirmEmbeddedDSHSubagentProcessExited(
      parentSessionID: child.parentSessionID, childID: child.childID, taskID: taskID)
  }
}

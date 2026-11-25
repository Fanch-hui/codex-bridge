import BridgeACP
import BridgeAgentCore
import BridgeCodexRPC
import BridgeDomain
import BridgeEmbeddedDSH
import BridgeFiles
import BridgeMCP
import BridgeSecurity
import BridgeServiceApplication
import BridgeServiceCore
import Crypto
import Foundation

extension ServiceEmbeddedDSHController {
  func scheduleWorkspaceMerge(rootID: String, childID: String) {
    let id = Self.workspaceID(rootID: rootID, childID: childID)
    guard !isShuttingDown, !isChangingWorkbenchEnabled, workspaceMergeTasks[id] == nil else {
      return
    }
    workspaceMergeTasks[id] = Task {
      await self.mergeWorkspaceIfAvailable(rootID: rootID, childID: childID)
      self.workspaceMergeTasks.removeValue(forKey: id)
    }
  }

  func startWorkspaceMergeMonitor() {
    guard workspaceMergeMonitor == nil, !isShuttingDown else { return }
    workspaceMergeMonitor = Task { [weak self, application] in
      let streams = await application.workspaceMergeChangeStreams()
      await self?.retryPendingWorkspaces()
      await withTaskGroup(of: Void.self) { group in
        for stream in streams {
          group.addTask { [weak self] in
            for await _ in stream {
              guard !Task.isCancelled, let self else { return }
              await self.retryPendingWorkspaces()
            }
          }
        }
        await group.waitForAll()
      }
    }
  }

  func retryPendingWorkspaces(rootID: String? = nil) async {
    guard !isShuttingDown else { return }
    do {
      try await requireWorkbenchEnabled()
    } catch WorkbenchAvailabilityError.disabled {
      return
    } catch WorkbenchAvailabilityError.busy {
      return
    } catch is CancellationError {
      return
    } catch {
      await receive(
        EmbeddedDSHEvent(
          sessionID: rootID, type: "workspace.mergeFailed",
          payload: .object([
            "workspaceStatus": .string("pending"),
            "message": .string("读取工作台状态失败，子 Agent 的结果已保留。"),
          ])))
      return
    }
    startWorkspaceMergeMonitor()
    let pending: [WorkbenchWorkspaceRecord]
    do {
      pending = try await pendingWorkspaces()
    } catch {
      await receive(
        EmbeddedDSHEvent(
          sessionID: rootID, type: "workspace.mergeFailed",
          payload: .object([
            "workspaceStatus": .string("pending"),
            "message": .string("读取待合并任务失败，子 Agent 的结果已保留。"),
          ])))
      return
    }
    for record in pending where rootID == nil || record.rootID == rootID {
      scheduleWorkspaceMerge(rootID: record.rootID, childID: record.childID)
    }
  }

  func mergeWorkspaceIfAvailable(rootID: String, childID: String) async {
    guard !isShuttingDown else { return }
    startWorkspaceMergeMonitor()
    await workspaceValidationExecution.acquire()
    defer { workspaceValidationExecution.release() }
    guard !isShuttingDown, !Task.isCancelled else { return }
    let id = Self.workspaceID(rootID: rootID, childID: childID)
    do {
      guard var record = try await workspaceRecord(id: id), record.status == "pending",
        let child = try await application.embeddedDSHSubagent(
          parentSessionID: rootID, childID: childID),
        child.currentTaskID?.rawValue == record.taskID, child.currentStatus?.isTerminal == true,
        try await store.workspaceMergeRecoveries(projectID: child.projectID).isEmpty
      else { return }
      let scope = try await recoverWorkspaceValidationProcesses()
      try await discardRecordedCandidate(&record, workspaceID: id)
      try await applyWorkspaceResolutions(&record, workspaceID: id)
      try await prepareAndMergeWorkspace(&record, child: child, scope: scope)
      await receive(
        EmbeddedDSHEvent(
          sessionID: rootID, type: "workspace.merge",
          payload: .object([
            "childID": .string(childID), "workspaceStatus": .string(record.status),
          ])))
    } catch {
      let reason = OutboundContentSecurity.redactedSecrets(
        String(describing: error), maximumUTF8Bytes: 1_024)
      do {
        if var record = try await workspaceRecord(id: id), record.status == "pending" {
          let child = try await application.embeddedDSHSubagent(
            parentSessionID: rootID, childID: childID)
          let recoveries: [ServiceWorkspaceMergeRecovery]
          if let child {
            recoveries = try await store.workspaceMergeRecoveries(projectID: child.projectID)
          } else {
            recoveries = []
          }
          record.status =
            recoveries.contains(where: { $0.workspaceID == id })
            ? "recovery_required" : "validation_required"
          record.failureReason = reason
          try await persistWorkspaceRecord(record)
        }
      } catch {
        await receive(
          EmbeddedDSHEvent(
            sessionID: rootID, type: "workspace.mergeFailed",
            payload: .object([
              "childID": .string(childID), "workspaceStatus": .string("pending"),
              "message": .string("保存合并状态失败，子 Agent 的结果已保留。"),
            ])))
        return
      }
      await receive(
        EmbeddedDSHEvent(
          sessionID: rootID, type: "workspace.mergeFailed",
          payload: .object([
            "childID": .string(childID), "workspaceStatus": .string("pending"),
            "message": .string(reason),
          ])))
    }
  }

  func acquireMergeLease(rootID: String, owner: String) async throws -> String? {
    do {
      let lease = try await invoke(
        action: "workspace.acquire",
        payload: .object([
          "sessionId": .string(rootID), "ownerId": .string(owner), "wait": .bool(false),
        ]))
      if lease["acquired"]?.boolValue == false { return nil }
      guard lease["acquired"]?.boolValue == true, let token = lease["token"]?.stringValue else {
        throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_lease")
      }
      return token
    } catch {
      await cancelMergeLease(rootID: rootID, owner: owner)
      throw error
    }
  }

  func releaseMergeLease(rootID: String, owner: String, token: String) async throws {
    do {
      _ = try await invoke(
        action: "workspace.release",
        payload: .object([
          "sessionId": .string(rootID), "ownerId": .string(owner), "token": .string(token),
        ]))
    } catch {
      // The file operation has finished; cancel also handles a lost release receipt.
      await cancelMergeLease(rootID: rootID, owner: owner)
      throw error
    }
  }

  private func cancelMergeLease(rootID: String, owner: String) async {
    let cleanup = Task.detached { [self] in
      try await invoke(
        action: "workspace.cancel",
        payload: .object(["sessionId": .string(rootID), "ownerId": .string(owner)]))
    }
    do { _ = try await cleanup.value } catch {
      await receive(
        EmbeddedDSHEvent(
          sessionID: rootID, type: "workspace.mergeFailed",
          payload: .object([
            "workspaceStatus": .string("pending"),
            "message": .string("合并写入租约未能确认释放，请恢复工作台连接。"),
          ])))
    }
  }
}

import BridgeAgentCore
import Foundation
import GRDB

extension SimpleServiceStore {
  @discardableResult
  public func markIncompleteTasksUnknown(at date: Date) throws -> [ServiceTaskRecord] {
    try ServiceValidation.date(date, field: "recovery.date")
    do {
      return try database.write { db in
        let rows = try Row.fetchAll(
          db,
          sql: """
            SELECT * FROM bridge_service_tasks
            WHERE status IN (
              'awaiting_local_approval', 'starting', 'running', 'waiting_for_codex_approval', 'unknown'
            )
            ORDER BY created_at, task_id
            """
        )
        var updated: [ServiceTaskRecord] = []
        updated.reserveCapacity(rows.count)
        for row in rows {
          let task = try Self.decodeTask(row)
          if task.isQueued {
            continue
          }
          if task.state.status == .awaitingLocalApproval,
            task.requiresLocalStartApproval
          {
            continue
          }
          let embeddedDSH = try Self.isEmbeddedDSHTask(task.id, in: db)
          let ownedProcess = embeddedDSH || task.providerID == AgentProviderID.claudeCode.rawValue
          if ownedProcess, task.state.status == .unknown { continue }
          let wasNotStarted = task.state.status == .awaitingLocalApproval
          let recoveredStatus: ServiceTaskStatus =
            ownedProcess && !wasNotStarted ? .unknown : .interrupted
          let recoverySummary: String
          if recoveredStatus == .unknown {
            recoverySummary =
              "The service restarted; the provider process and result require reconciliation."
          } else if wasNotStarted {
            recoverySummary = "The service restarted before task execution began."
          } else {
            recoverySummary = "The service restarted without an attached provider run."
          }
          let supervisorStatus: ServiceSupervisorStatus =
            task.state.supervisorStatus == .disabled ? .disabled : .degraded
          let state = try ServiceTaskState(
            codexThreadID: task.state.codexThreadID,
            codexTurnID: task.state.codexTurnID,
            providerSessionID: task.state.providerSessionID,
            providerRunID: task.state.providerRunID,
            status: recoveredStatus,
            supervisorStatus: supervisorStatus,
            currentStep: task.state.currentStep,
            changedFiles: task.state.changedFiles,
            resultSummary: task.state.resultSummary,
            supervisorSummary: task.state.supervisorSummary,
            failureCode: task.state.failureCode
              ?? (recoveredStatus == .unknown
                ? (embeddedDSH ? "dsh_recovery_pending" : "agent_process_recovery_pending")
                : "service_restarted")
          )
          let recovered = try task.replacingState(state, updatedAt: date)
          try Self.validateTransition(from: task.state.status, to: recoveredStatus)
          try updateTaskRow(recovered, in: db)
          try Self.insert(
            ServiceTaskEventDraft(
              kind: recoveredStatus == .unknown ? .taskMarkedUnknown : .taskInterrupted,
              summary: recoverySummary,
              createdAt: date
            ),
            taskID: task.id,
            in: db
          )
          updated.append(recovered)
        }
        return updated
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }
}

import BridgeAgentCore
import BridgeDomain
import Foundation
import GRDB

extension SimpleServiceStore {
  func markClaudeProcessUnknown(taskID: TaskID, at date: Date) throws -> ServiceTaskRecord {
    try updateClaudeProcessRecovery(taskID: taskID, at: date, stopped: false)
  }

  func confirmClaudeProcessStopped(taskID: TaskID, at date: Date) throws -> ServiceTaskRecord {
    try updateClaudeProcessRecovery(taskID: taskID, at: date, stopped: true)
  }

  private func updateClaudeProcessRecovery(taskID: TaskID, at date: Date, stopped: Bool) throws
    -> ServiceTaskRecord
  {
    try ServiceValidation.date(date, field: "agent.recoveryDate")
    do {
      return try database.write { db in
        guard let row = try Self.taskRow(id: taskID, in: db) else {
          throw ServiceStoreError.unknownTask(taskID)
        }
        let task = try Self.decodeTask(row)
        guard task.providerID == AgentProviderID.claudeCode.rawValue,
          try !Self.isEmbeddedDSHTask(taskID, in: db)
        else { throw ServiceStoreError.invalidArgument("agent.recoveryIdentity") }
        let destination: ServiceTaskStatus = stopped ? .interrupted : .unknown
        if task.state.status == destination { return task }
        if stopped, task.state.status != .unknown {
          throw ServiceStoreError.invalidArgument("agent.recoveryState")
        }
        try Self.validateTransition(from: task.state.status, to: destination)
        let state = try ServiceTaskState(
          codexThreadID: task.state.codexThreadID, codexTurnID: task.state.codexTurnID,
          providerSessionID: task.state.providerSessionID, providerRunID: task.state.providerRunID,
          status: destination, supervisorStatus: task.state.supervisorStatus,
          currentStep: task.state.currentStep, changedFiles: task.state.changedFiles,
          resultSummary: task.state.resultSummary, supervisorSummary: task.state.supervisorSummary,
          failureCode: stopped ? "agent_process_interrupted" : "agent_process_recovery_pending")
        let updated = try task.replacingState(state, updatedAt: date)
        try updateTaskRow(updated, in: db)
        try Self.insert(
          ServiceTaskEventDraft(
            kind: stopped ? .taskInterrupted : .taskMarkedUnknown,
            summary: stopped
              ? "The provider process stopped; its previous result was unavailable."
              : "The provider process and result require reconciliation.",
            createdAt: date), taskID: taskID, in: db)
        return updated
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }
}

extension ServiceTaskManager {
  public func markClaudeProcessUnknown(taskID: TaskID) async throws -> ServiceTaskRecord {
    let result = try await store.markClaudeProcessUnknown(taskID: taskID, at: now())
    changes.publish()
    return result
  }

  /// Call only after the task's owned process tree has stopped.
  public func confirmClaudeProcessStopped(taskID: TaskID) async throws -> ServiceTaskRecord {
    let result = try await store.confirmClaudeProcessStopped(taskID: taskID, at: now())
    changes.publish()
    return result
  }
}

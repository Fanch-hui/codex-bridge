import BridgeDomain
import Foundation
import GRDB

extension SimpleServiceStore {
  func markEmbeddedDSHProcessUnknown(taskID: TaskID, at date: Date) throws -> ServiceTaskRecord {
    try ServiceValidation.date(date, field: "dsh.recoveryDate")
    do {
      return try database.write { db in
        guard try Self.isEmbeddedDSHTask(taskID, in: db),
          let row = try Self.taskRow(id: taskID, in: db)
        else { throw ServiceStoreError.invalidArgument("dsh.recoveryIdentity") }
        let task = try Self.decodeTask(row)
        if task.state.status == .unknown { return task }
        try Self.validateTransition(from: task.state.status, to: .unknown)
        let state = try ServiceTaskState(
          codexThreadID: task.state.codexThreadID, codexTurnID: task.state.codexTurnID,
          providerSessionID: task.state.providerSessionID, providerRunID: task.state.providerRunID,
          status: .unknown, supervisorStatus: task.state.supervisorStatus,
          currentStep: task.state.currentStep, changedFiles: task.state.changedFiles,
          resultSummary: task.state.resultSummary, supervisorSummary: task.state.supervisorSummary,
          failureCode: "dsh_recovery_pending"
        )
        let updated = try task.replacingState(state, updatedAt: date)
        try updateTaskRow(updated, in: db)
        try Self.insert(
          ServiceTaskEventDraft(
            kind: .taskMarkedUnknown,
            summary: "The provider process and result require reconciliation.", createdAt: date),
          taskID: taskID, in: db)
        return updated
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  func reconcileEmbeddedDSHSubagent(
    parentSessionID: String, childID: String, taskID: TaskID,
    outcome: EmbeddedDSHReconciledOutcome, at date: Date
  ) throws -> ServiceTaskRecord {
    try Self.validateEmbeddedDSHIdentity(.init(parentSessionID: parentSessionID, childID: childID))
    try ServiceValidation.date(date, field: "dsh.recoveryDate")
    do {
      return try database.write { db in
        guard
          let binding = try Self.embeddedDSHBinding(
            parentSessionID: parentSessionID, childID: childID, in: db),
          binding.currentTaskID == taskID,
          let row = try Self.taskRow(id: taskID, in: db)
        else { throw ServiceStoreError.invalidArgument("dsh.recoveryIdentity") }
        let task = try Self.decodeTask(row)
        if task.state.status.isTerminal {
          guard try Self.matchesReconciledOutcome(task, outcome: outcome) else {
            throw ServiceStoreError.invalidArgument("dsh.recoveryConflict")
          }
          return task
        }
        guard task.state.status == .unknown else {
          throw ServiceStoreError.invalidArgument("dsh.recoveryState")
        }
        let status: ServiceTaskStatus
        let eventKind: ServiceTaskEventKind
        let summary: String
        let result: String?
        let failureCode: String?
        let changedFiles: [String]
        switch outcome {
        case .completed(let resultSummary, let files):
          status = .completed
          eventKind = .taskCompleted
          summary = "The provider's completed result was recovered."
          result = resultSummary
          failureCode = nil
          changedFiles = try ServiceTaskProgressProjection.changedFiles(files)
        case .failed(let code, let failureSummary):
          status = .failed
          eventKind = .taskFailed
          summary = failureSummary
          result = failureSummary
          failureCode = code
          changedFiles = task.state.changedFiles
        case .interrupted(let interruptionSummary):
          status = .interrupted
          eventKind = .taskInterrupted
          summary = interruptionSummary
          result = task.state.resultSummary
          failureCode = "service_restarted"
          changedFiles = task.state.changedFiles
        }
        let state = try ServiceTaskState(
          codexThreadID: task.state.codexThreadID, codexTurnID: task.state.codexTurnID,
          providerSessionID: task.state.providerSessionID, providerRunID: task.state.providerRunID,
          status: status, supervisorStatus: task.state.supervisorStatus,
          currentStep: task.state.currentStep, changedFiles: changedFiles, resultSummary: result,
          supervisorSummary: task.state.supervisorSummary, failureCode: failureCode
        )
        let recovered = try task.replacingState(state, updatedAt: date)
        try updateTaskRow(recovered, in: db)
        try Self.insert(
          ServiceTaskEventDraft(kind: eventKind, summary: summary, createdAt: date),
          taskID: taskID, in: db)
        return recovered
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  private static func matchesReconciledOutcome(
    _ task: ServiceTaskRecord, outcome: EmbeddedDSHReconciledOutcome
  ) throws -> Bool {
    switch outcome {
    case .completed(let summary, let files):
      let expectedFiles = try ServiceTaskProgressProjection.changedFiles(files)
      return task.state.status == .completed && task.state.resultSummary == summary
        && task.state.changedFiles == expectedFiles
    case .failed(let code, let summary):
      return task.state.status == .failed && task.state.failureCode == code
        && task.state.resultSummary == summary
    case .interrupted:
      return task.state.status == .interrupted
    }
  }
}

import BridgeDomain
import BridgeServiceCore

extension ServiceExecutionCoordinator {
  public func scheduleStart(taskID: TaskID) throws {
    guard !isShuttingDown else {
      throw ExecutionServiceError.processUnavailable
    }
    guard scheduledStarts[taskID] == nil else {
      throw ExecutionServiceError.activeSession(taskID)
    }
    // Approval has been persisted; the service now owns startup independently
    // of the request that accepted the task.
    scheduledStarts[taskID] = Task { [weak self] in
      await self?.runScheduledStart(taskID: taskID)
    }
  }

  private func runScheduledStart(taskID: TaskID) async {
    do {
      _ = try await start(taskID: taskID)
    } catch {
      await failScheduledStart(taskID: taskID, error: error)
    }
    scheduledStarts.removeValue(forKey: taskID)
  }

  private func failScheduledStart(taskID: TaskID, error: any Error) async {
    guard !isShuttingDown, !finishedRuns.contains(taskID),
      let task = try? await tasks.task(id: taskID), task.state.status == .starting
    else { return }
    let persisted = await conversation.close(taskID: taskID)
    _ = try? await tasks.fail(
      taskID: taskID,
      failureCode: persisted
        ? (task.providerID == serviceCodexProviderID
          ? "execution_start_failed" : "agent_start_failed")
        : "conversation_persistence_failed",
      summary: persisted
        ? ExecutionStartFailurePresentation.summary(error, provider: task.providerID)
        : "The task conversation could not be persisted."
    )
  }
}

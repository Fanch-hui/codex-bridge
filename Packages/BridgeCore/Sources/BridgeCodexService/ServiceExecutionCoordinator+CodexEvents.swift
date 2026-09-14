import BridgeDomain
import BridgeServiceCore
import Foundation

extension ServiceExecutionCoordinator {
  func consume(_ event: ExecutionEvent, taskID: TaskID) async {
    do {
      switch event {
      case .planUpdated(let currentStep, _):
        _ = try await tasks.updatePlan(taskID: taskID, currentStep: currentStep)

      case .commandCompleted(let displayCommand, let exitCode, let status):
        let exit = exitCode.map { " (exit \($0))" } ?? ""
        let summary = "Codex command \(status.rawValue)\(exit): \(displayCommand)"
        _ = try await tasks.recordCommandCompletion(
          taskID: taskID,
          summary: summary
        )

      case .filesChanged(let relativePaths, let status):
        let changed = status == .completed ? relativePaths : []
        let summary =
          "Codex file change \(status.rawValue) for \(relativePaths.count) path(s)."
        _ = try await tasks.recordChangedFiles(
          taskID: taskID,
          relativePaths: changed,
          summary: summary
        )

      case .approvalRequested(let approval):
        guard approval.isBlocking else { return }
        _ = try await tasks.markWaitingForCodexApproval(taskID: taskID)

      case .agentMessageDelta(let delta):
        await conversation.appendDelta(taskID: taskID, itemID: delta.itemID, delta: delta.delta)

      case .reasoningDelta(let delta):
        await conversation.appendDelta(
          taskID: taskID,
          itemID: delta.itemID,
          delta: delta.delta,
          kind: .reasoning
        )

      case .toolCall(let call):
        await conversation.upsertToolCall(taskID: taskID, call: call)

      case .toolCallProgress(let itemID, let progress):
        await conversation.appendToolCallProgress(
          taskID: taskID, itemID: itemID, progress: progress)

      case .turnCompleted(let messages):
        await conversation.finalize(taskID: taskID, messages: messages)

      case .completed(let resultSummary):
        try await closeConversation(taskID: taskID)
        let current = try await requiredTask(taskID)
        _ = try await tasks.complete(
          taskID: taskID,
          resultSummary: resultSummary,
          changedFiles: current.state.changedFiles
        )

      case .interrupted:
        try await closeConversation(taskID: taskID)
        _ = try await tasks.interrupt(
          taskID: taskID,
          summary: "Codex confirmed that the active Turn was interrupted."
        )

      case .failed(let code, let summary):
        await conversation.appendAgentMessage(taskID: taskID, content: summary)
        try await closeConversation(taskID: taskID)
        _ = try await tasks.fail(
          taskID: taskID,
          failureCode: code,
          summary: summary
        )
      }
    } catch {
      await execution.stop(taskID: taskID)
      _ = await conversation.close(taskID: taskID)
      _ = try? await tasks.fail(
        taskID: taskID,
        failureCode: "execution_state_update_failed",
        summary: Self.persistenceFailureSummary(error)
      )
    }
  }
}

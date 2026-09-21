import BridgeAgentCore
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func startTaskQueueProcessor() {
    guard taskQueueProcessor == nil else { return }
    let taskChanges = tasks.changes.subscribe()
    let workspaceChanges = workspaceGate.changes.subscribe()
    taskQueueProcessor = Task { [weak self] in
      await withTaskGroup(of: Void.self) { group in
        group.addTask { [weak self] in
          for await _ in taskChanges {
            guard !Task.isCancelled, let self else { return }
            await self.drainQueuedTasks()
          }
        }
        group.addTask { [weak self] in
          for await _ in workspaceChanges {
            guard !Task.isCancelled, let self else { return }
            await self.drainQueuedTasks()
          }
        }
        await group.waitForAll()
      }
    }
    Task { [weak self] in await self?.drainQueuedTasks() }
  }

  func stopTaskQueueProcessor() {
    taskQueueProcessor?.cancel()
    taskQueueProcessor = nil
  }

  func drainQueuedTasks() async {
    guard let queued = try? await tasks.queuedTasks(limit: 500) else { return }
    for task in queued {
      do {
        guard try await tasks.activeWriteTask(projectID: task.projectID) == nil else {
          continue
        }
      } catch {
        continue
      }
      do {
        guard try await workspaceGate.workspaceBusyDetail(projectID: task.projectID) == nil else {
          continue
        }
      } catch {
        continue
      }
      guard await recheckQueuedTask(task) else { continue }
      guard let admitted = try? await tasks.promoteQueued(taskID: task.id) else {
        continue
      }
      do {
        if admitted.requiresLocalStartApproval {
          if try await settings.taskStartApprovalMode() == .auto {
            try await approveAndStartTask(admitted.id, automatically: true)
          }
        } else {
          try await approveAndStartTask(
            admitted.id,
            summary: "The local App submitted this queued provider invocation."
          )
        }
      } catch {
        _ = try? await tasks.fail(
          taskID: admitted.id,
          failureCode: "queued_start_failed",
          summary: "The queued task could not start after admission."
        )
      }
    }
  }

  private func recheckQueuedTask(_ task: ServiceTaskRecord) async -> Bool {
    guard let project = try? await projects.project(id: task.projectID) else {
      _ = try? await tasks.fail(
        taskID: task.id,
        failureCode: "queued_project_missing",
        summary: "The project no longer exists, so the queued task was cancelled."
      )
      return false
    }
    guard project.accessPolicy.write != .denied,
      !task.networkAllowed || project.accessPolicy.network != .denied
    else {
      _ = try? await tasks.fail(
        taskID: task.id,
        failureCode: "queued_policy_denied",
        summary: "The project policy no longer allows this queued task."
      )
      return false
    }
    guard await recheckQueuedModel(task, project: project) else {
      _ = try? await tasks.fail(
        taskID: task.id,
        failureCode: "queued_model_unavailable",
        summary: "The selected model is no longer available for this queued task."
      )
      return false
    }
    guard task.providerID != serviceCodexProviderID else { return true }
    guard let installationID = task.installationID, let registry = agentRegistry else {
      _ = try? await tasks.fail(
        taskID: task.id,
        failureCode: "queued_agent_unavailable",
        summary: "The queued Agent installation is no longer available."
      )
      return false
    }
    do {
      let installation = try await registry.validateForExecution(
        installationID: AgentInstallationID(rawValue: installationID)
      )
      guard installation.providerID.rawValue == task.providerID else { throw CancellationError() }
      return true
    } catch {
      _ = try? await tasks.fail(
        taskID: task.id,
        failureCode: "queued_agent_unavailable",
        summary: "The queued Agent installation is no longer available."
      )
      return false
    }
  }

  private func recheckQueuedModel(
    _ task: ServiceTaskRecord,
    project: ServiceProjectRecord
  ) async -> Bool {
    let usesExplicitSelection =
      task.executionModel != serviceDefaultProviderExecutionModel
      || task.executionEffort != serviceDefaultProviderExecutionEffort
      || task.fastMode
    guard usesExplicitSelection else { return true }
    do {
      let deadline = ContinuousClock.now.advanced(by: .seconds(30))
      if task.providerID == serviceCodexProviderID {
        let models = try await catalog.listModels(deadline: deadline).models
        guard let model = models.first(where: { $0.modelID == task.executionModel }) else {
          return false
        }
        guard
          task.executionEffort == serviceDefaultProviderExecutionEffort
            || model.reasoningEfforts.contains(task.executionEffort),
          !task.fastMode || model.supportsFastMode
        else { return false }
        return true
      }
      guard let installationID = task.installationID, let registry = agentRegistry else {
        return false
      }
      let models = try await serviceAgentModelCatalog(
        registry: registry,
        installationID: AgentInstallationID(rawValue: installationID),
        projectRoot: project.root.canonicalPath,
        selectedModelID: nil
      )
      guard let model = models.first(where: { $0.id == task.executionModel }) else {
        return false
      }
      return task.executionEffort == serviceDefaultProviderExecutionEffort
        || model.supportedReasoningEfforts.contains(task.executionEffort)
    } catch {
      return false
    }
  }

  public func shutdownTaskQueueProcessor() {
    stopTaskQueueProcessor()
  }
}

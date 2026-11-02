import BridgeServiceCore
import Foundation

public struct ServiceAppUpdatePreparationStatus: Sendable {
  public let canInstall: Bool
  public let waitingReason: String?
  public let blockers: [ServiceAppUpdateBlocker]
}

public struct ServiceAppUpdateBlocker: Sendable {
  public let kind: String
  public let id: String
  public let projectID: String?
  public let label: String
}

extension BridgeServiceApplication {
  public func prepareAppUpdateStatus() async throws -> ServiceAppUpdatePreparationStatus {
    let canInstall = try await prepareAppUpdate()
    guard !canInstall else {
      return ServiceAppUpdatePreparationStatus(canInstall: true, waitingReason: nil, blockers: [])
    }
    let activeTasks = try await tasks.nonterminalTasks()
    let executions = try await tasks.embeddedDSHExecutions()
    let unscopedSessions = activeUnscopedWorkbenchSessionIDs()
    let maintenance = activeWorkbenchMaintenanceOperationIDs()
    let commands = await directCommands.allSessions().filter { $0.status == "running" }
    let taskCount = activeTasks.count
    let dshCount = executions.count + unscopedSessions.count
    let commandCount = commands.count
    var reasons: [String] = []
    if taskCount > 0 { reasons.append("\(taskCount) 个未结束的 Agent 任务") }
    if dshCount > 0 { reasons.append("\(dshCount) 个工作台会话正在运行") }
    if !maintenance.isEmpty { reasons.append("\(maintenance.count) 个插件操作正在进行") }
    if commandCount > 0 { reasons.append("\(commandCount) 条运行中的 Direct 命令") }
    if let workspaceReason = await workspaceGate.appUpdateWaitingReason() {
      reasons.append(workspaceReason)
    }
    let reason = reasons.isEmpty ? "正在等待后台服务空闲。" : "正在等待" + reasons.joined(separator: "、") + "完成。"
    let blockers =
      activeTasks.map {
        ServiceAppUpdateBlocker(
          kind: "task", id: $0.id.rawValue, projectID: $0.projectID.rawValue,
          label: "Agent 任务 · " + String($0.id.rawValue.prefix(8)))
      }
      + executions.map {
        ServiceAppUpdateBlocker(
          kind: "workbench", id: $0.sessionID, projectID: $0.projectID.rawValue,
          label: "工作台会话 · " + String($0.sessionID.prefix(8)))
      }
      + unscopedSessions.map {
        ServiceAppUpdateBlocker(
          kind: "workbench", id: $0, projectID: nil, label: "工作台会话 · " + String($0.prefix(8)))
      }
      + maintenance.map {
        ServiceAppUpdateBlocker(
          kind: "maintenance", id: $0, projectID: nil, label: "插件操作 · " + String($0.prefix(8)))
      }
      + commands.map {
        ServiceAppUpdateBlocker(
          kind: "command", id: $0.sessionID, projectID: $0.projectID.rawValue,
          label: "运行中的命令 · " + String($0.sessionID.prefix(8)))
      }
    return ServiceAppUpdatePreparationStatus(
      canInstall: false, waitingReason: reason, blockers: Array(blockers.prefix(20)))
  }

  public func prepareAppUpdate() async throws -> Bool {
    if let preparation = appUpdatePreparationTask {
      return try await preparation.value
    }
    let preparation = Task { [weak self] in
      guard let self else { return false }
      return try await self.performAppUpdatePreparation()
    }
    appUpdatePreparationTask = preparation
    do {
      let result = try await preparation.value
      appUpdatePreparationTask = nil
      return result
    } catch {
      appUpdatePreparationTask = nil
      throw error
    }
  }

  public func prepareIdleServiceShutdown() async throws -> Bool {
    guard await workspaceGate.beginIdleServiceShutdown() else { return false }
    do {
      guard try await appUpdateIsIdle() else {
        await workspaceGate.cancelIdleServiceShutdown()
        return false
      }
      await workspaceGate.commitServiceShutdown()
      return true
    } catch {
      await workspaceGate.cancelIdleServiceShutdown()
      throw error
    }
  }

  public func cancelAppUpdate() async throws {
    await workspaceGate.cancelAppUpdate()
  }

  private func appUpdateIsIdle() async throws -> Bool {
    guard try await tasks.nonterminalTasks().isEmpty else { return false }
    guard try await tasks.activeEmbeddedDSHExecutionCount() == 0 else { return false }
    guard activeUnscopedWorkbenchSessionIDs().isEmpty else { return false }
    guard activeWorkbenchMaintenanceOperationIDs().isEmpty else { return false }
    return await !directCommands.allSessions().contains { $0.status == "running" }
  }

  private func performAppUpdatePreparation() async throws -> Bool {
    guard await workspaceGate.beginAppUpdate() else { return false }
    do {
      guard try await appUpdateIsIdle() else {
        await workspaceGate.cancelAppUpdate()
        return false
      }
      return true
    } catch {
      await workspaceGate.cancelAppUpdate()
      throw error
    }
  }
}

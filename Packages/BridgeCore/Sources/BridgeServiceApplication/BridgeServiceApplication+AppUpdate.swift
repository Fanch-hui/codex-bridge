import BridgeServiceCore
import Foundation

public struct ServiceAppUpdatePreparationStatus: Sendable {
  public let canInstall: Bool
  public let waitingReason: String?
}

extension BridgeServiceApplication {
  public func prepareAppUpdateStatus() async throws -> ServiceAppUpdatePreparationStatus {
    let canInstall = try await prepareAppUpdate()
    guard !canInstall else {
      return ServiceAppUpdatePreparationStatus(canInstall: true, waitingReason: nil)
    }
    let taskCount = try await tasks.nonterminalTasks().count
    let commandCount = await directCommands.allSessions().filter { $0.status == "running" }.count
    var reasons: [String] = []
    if taskCount > 0 { reasons.append("\(taskCount) 个未结束的 Agent 任务") }
    if commandCount > 0 { reasons.append("\(commandCount) 条运行中的 Direct 命令") }
    if let workspaceReason = await workspaceGate.appUpdateWaitingReason() {
      reasons.append(workspaceReason)
    }
    let reason = reasons.isEmpty ? "正在等待后台服务空闲。" : "正在等待" + reasons.joined(separator: "、") + "完成。"
    return ServiceAppUpdatePreparationStatus(canInstall: false, waitingReason: reason)
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

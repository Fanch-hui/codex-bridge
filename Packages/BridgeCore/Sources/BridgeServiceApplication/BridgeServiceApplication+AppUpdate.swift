import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
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

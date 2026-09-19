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

  public func cancelAppUpdate() async throws {
    await workspaceGate.cancelAppUpdate()
  }

  private func performAppUpdatePreparation() async throws -> Bool {
    guard await workspaceGate.beginAppUpdate() else { return false }
    do {
      guard try await tasks.nonterminalTasks().isEmpty else {
        await workspaceGate.cancelAppUpdate()
        return false
      }
      let directBusy = await directCommands.allSessions().contains { $0.status == "running" }
      guard !directBusy else {
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

import BridgeACP
import BridgeEmbeddedDSH
import Foundation

extension ServiceEmbeddedDSHController {
  func scheduleIdleApply() -> ACPJSONValue {
    guard idleApplyTask == nil else { return .object(["scheduled": .bool(true)]) }
    idleApplyTask = Task {
      defer { self.idleApplyTask = nil }
      do {
        while !self.isShuttingDown {
          try Task.checkCancellation()
          self.isApplyingConfiguration = true
          let executions = try await self.application.embeddedDSHExecutions()
          let chat = await self.application.activeUnscopedWorkbenchSessionIDs()
          let maintenance = await self.application.activeWorkbenchMaintenanceOperationIDs()
          let configuration = try await self.invoke(
            action: "configuration.status", payload: .object([:]))
          let installs = configuration["activePluginInstalls"]?.intValue ?? 0
          let applying = configuration["plugins"]?["status"]?.stringValue == "applying"
          if executions.isEmpty, chat.isEmpty, maintenance.isEmpty, installs == 0, !applying,
            self.operationTasks.isEmpty,
            self.activeMutationRequests == 0, self.bindingTasks.isEmpty
          {
            _ = try await self.restartEngine()
            self.isApplyingConfiguration = false
            await self.receive(EmbeddedDSHEvent(type: "runtime.restarted", payload: .object([:])))
            await self.receive(
              EmbeddedDSHEvent(type: "configuration.changed", payload: .object([:])))
            return
          }
          self.isApplyingConfiguration = false
          try await Task.sleep(for: .seconds(3))
        }
      } catch is CancellationError {
        self.isApplyingConfiguration = false
        return
      } catch {
        self.isApplyingConfiguration = false
        let failure = BridgeServiceRequestController.map(error)
        await self.receive(
          EmbeddedDSHEvent(
            type: "configuration.applyFailed",
            payload: .object(["message": .string(failure.message)])))
      }
    }
    return .object(["scheduled": .bool(true)])
  }
}

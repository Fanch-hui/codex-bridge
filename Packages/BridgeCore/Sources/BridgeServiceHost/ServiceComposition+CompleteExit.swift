import BridgeACP
import BridgeIPC
import Foundation

extension ServiceComposition {
  func providerGatewayRequest(_ request: IPCProviderGatewayRequest) async throws
    -> IPCProviderGatewayResponse
  {
    if request.action == "service.prepareCompleteExit" {
      let result = try await prepareCompleteExit()
      return IPCProviderGatewayResponse(
        resultJSON: String(decoding: try result.encodedData(), as: UTF8.self))
    }
    guard completeExitState == "idle" || request.action == "status" else {
      throw WorkbenchAvailabilityError.busy
    }
    return try await providerGateway.call(request)
  }

  func prepareCompleteExit() async throws -> ACPJSONValue {
    if completeExitState != "idle" { return completeExitStatus() }
    completeExitState = "waiting"
    do {
      let idle = try await application.prepareIdleServiceShutdown { [embeddedDSH] in
        do {
          try await embeddedDSH.ensureWorkbenchIdle()
          return true
        } catch WorkbenchAvailabilityError.busy {
          return false
        }
      }
      guard idle else {
        completeExitState = "idle"
        return .object([
          "state": .string("busy"),
          "message": .string("仍有任务、审批或维护操作，请完成或停止后再彻底退出。"),
        ])
      }
      completeExitTask = Task { await self.finishCompleteExit() }
      return completeExitStatus()
    } catch {
      completeExitState = "idle"
      throw error
    }
  }

  private func finishCompleteExit() async {
    do {
      await providerGateway.stopAccepting()
      await applicationMode.shutdown()
      try await embeddedDSH.shutdown()
      try await providerGateway.shutdown()
      await shutdown()
      completeExitState = "ready"
    } catch {
      completeExitState = "failed"
      completeExitMessage = "后台进程尚未确认退出，未强制终止；请检查诊断，应用将保持打开。"
    }
    completeExitTask = nil
  }

  private func completeExitStatus() -> ACPJSONValue {
    .object([
      "state": .string(completeExitState),
      "message": completeExitMessage.map(ACPJSONValue.string) ?? .null,
    ])
  }
}

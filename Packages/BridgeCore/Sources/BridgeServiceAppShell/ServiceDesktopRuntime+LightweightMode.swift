import AppKit
import BridgeIPC
import BridgeServiceAppCore
import Foundation

extension BridgeServiceAppModel {
  func lightweightModeDidChange() {
    if isLightweightMode != false {
      closeConversation()
      paneConversations.pause()
    } else if isLightweightMode == false {
      paneConversations.sync(tasks: tasks, client: client)
      if let taskID = selectedTaskID, conversation == nil {
        openConversation(taskID: taskID)
      }
    }
  }
}

extension BridgeServiceAppModel {
  func quitCompletely() {
    guard !completeExitInProgress else { return }
    completeExitInProgress = true
    postToast("正在等待后台请求完成后退出。", symbol: "clock", tone: .running)
    Task {
      defer { completeExitInProgress = false }
      do {
        if !completeExitServicePrepared {
          let client = try currentClient()
          try await CompleteServiceExit.prepare(using: client)
          completeExitServicePrepared = true
        }
        pollingTask?.cancel()
        pollingTask = nil
        stateChangesTask?.cancel()
        stateChangesTask = nil
        try await registration.stopTemporarily()
        completeExitPrepared = true
        NSApp.terminate(nil)
      } catch {
        errorMessage = Self.message(error)
      }
    }
  }

  func toggleApplicationModeFromTray() {
    Task {
      do {
        let client = try currentClient()
        try await refreshGatewayStatus(client)
        guard let isLightweightMode else { return }
        let mode = isLightweightMode ? "full" : "lite"
        let response = try await client.providerGateway(
          IPCProviderGatewayRequest(action: "mode.set", payloadJSON: "{\"mode\":\"\(mode)\"}"))
        try applyProviderGatewayStatus(response.resultJSON)
        var pending = try JSONDecoder().decode(
          ModeTransition.self, from: Data(response.resultJSON.utf8))
        while pending.transition == "waiting" {
          try await Task.sleep(for: .seconds(1))
          let status = try await client.providerGateway(IPCProviderGatewayRequest(action: "status"))
          try applyProviderGatewayStatus(status.resultJSON)
          pending = try JSONDecoder().decode(
            ModeTransition.self, from: Data(status.resultJSON.utf8))
        }
        if let error = pending.error { errorMessage = error }
      } catch {
        errorMessage = Self.message(error)
      }
    }
  }

  func toggleModelGatewayFromTray() {
    Task {
      do {
        let client = try currentClient()
        try await refreshGatewayStatus(client)
        guard let isModelGatewayEnabled else { return }
        _ = try await client.providerGateway(
          IPCProviderGatewayRequest(
            action: "service.setEnabled",
            payloadJSON: "{\"enabled\":\(isModelGatewayEnabled ? "false" : "true")}"))
        try await refreshGatewayStatus(client)
      } catch {
        errorMessage = Self.message(error)
      }
    }
  }

  private func refreshGatewayStatus(_ client: any BridgeServiceClientProtocol) async throws {
    let status = try await client.providerGateway(IPCProviderGatewayRequest(action: "status"))
    try applyProviderGatewayStatus(status.resultJSON)
  }
}

private struct ModeTransition: Decodable {
  let transition: String?
  let error: String?
}

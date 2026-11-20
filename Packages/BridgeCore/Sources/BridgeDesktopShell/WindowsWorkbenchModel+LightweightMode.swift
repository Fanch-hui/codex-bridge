#if os(Windows) || os(Linux)
  import BridgeIPC
  import Foundation

  extension WindowsWorkbenchModel {
    func lightweightModeDidChange(from previous: Bool? = nil) {
      if isLightweightMode != false {
        deferredCatalogTask?.cancel()
        deferredCatalogTask = nil
        closeConversation()
        paneConversations.pause()
      } else if isLightweightMode == false {
        paneConversations.sync(tasks: tasks, client: client)
        if let taskID = selectedTaskID, conversation == nil,
          let task = tasks.first(where: { $0.taskID == taskID })
        {
          openConversation(for: task)
        }
        if previous == true, connectionState == .connected {
          Task { [weak self] in await self?.refreshTasks() }
          scheduleDeferredConnectionWork(
            generation: connectionGeneration, notifyOnConnect: true)
        }
      }
    }
  }
#endif

#if os(Windows) || os(Linux)
  import BridgeServiceAppCore

  private struct TrayModeTransition: Decodable {
    let transition: String?
    let error: String?
  }

  extension WindowsWorkbenchModel {
    func toggleApplicationModeFromTray() async {
      do {
        try await refreshGatewayStatusFromTray()
        guard let isLightweightMode else { return }
        let mode = isLightweightMode ? "full" : "lite"
        let response = try await client.providerGateway(
          IPCProviderGatewayRequest(action: "mode.set", payloadJSON: "{\"mode\":\"\(mode)\"}"))
        try applyProviderGatewayStatus(response.resultJSON)
        var pending = try JSONDecoder().decode(
          TrayModeTransition.self, from: Data(response.resultJSON.utf8))
        while pending.transition == "waiting" {
          try await Task.sleep(for: .seconds(1))
          let status = try await client.providerGateway(IPCProviderGatewayRequest(action: "status"))
          try applyProviderGatewayStatus(status.resultJSON)
          pending = try JSONDecoder().decode(
            TrayModeTransition.self, from: Data(status.resultJSON.utf8))
        }
        if let error = pending.error { feedback.postAlert(error) }
      } catch {
        feedback.postAlert(BridgeServiceErrorMessage.message(error))
      }
    }

    func toggleModelGatewayFromTray() async {
      do {
        try await refreshGatewayStatusFromTray()
        guard let isModelGatewayEnabled else { return }
        _ = try await client.providerGateway(
          IPCProviderGatewayRequest(
            action: "service.setEnabled",
            payloadJSON: "{\"enabled\":\(isModelGatewayEnabled ? "false" : "true")}"))
        try await refreshGatewayStatusFromTray()
      } catch {
        feedback.postAlert(BridgeServiceErrorMessage.message(error))
      }
    }

    private func refreshGatewayStatusFromTray() async throws {
      let status = try await client.providerGateway(IPCProviderGatewayRequest(action: "status"))
      try applyProviderGatewayStatus(status.resultJSON)
    }
  }
#endif

#if os(Windows)
  import BridgeServiceAppCore

  @MainActor
  final class WindowsAuxiliaryRuntime {
    let workspace: WindowsWorkspaceModel
    let agentDefaults: WindowsAgentDefaultsModel
    let logs: WindowsLogModel
    let settings: WindowsSettingsModel
    let connections: WindowsConnectionModel

    init(
      client: any BridgeServiceClientProtocol,
      feedback: WindowsDesktopFeedbackStore
    ) {
      workspace = WindowsWorkspaceModel(client: client, feedback: feedback)
      agentDefaults = WindowsAgentDefaultsModel(client: client, feedback: feedback)
      logs = WindowsLogModel(client: client, feedback: feedback)
      settings = WindowsSettingsModel(client: client, feedback: feedback)
      connections = WindowsConnectionModel(client: client, feedback: feedback)
    }

    func refreshAll() async {
      await workspace.refresh()
      await logs.refresh()
      await connections.refresh()
      await settings.refresh()
      await agentDefaults.refresh()
    }

  }
#endif

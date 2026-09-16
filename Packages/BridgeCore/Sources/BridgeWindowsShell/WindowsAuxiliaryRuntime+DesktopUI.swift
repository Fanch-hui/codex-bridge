#if os(Windows)
  struct WindowsAuxiliaryDisplaySnapshot: Sendable {
    let workspace: WindowsWorkspaceDisplay
    let agentDefaults: WindowsAgentDefaultsDisplay
    let logs: WindowsLogDisplay
    let settings: WindowsSettingsDisplay
    let connections: WindowsConnectionDisplay
  }

  extension WindowsAuxiliaryRuntime {
    func desktopDisplaySnapshot() -> WindowsAuxiliaryDisplaySnapshot {
      return WindowsAuxiliaryDisplaySnapshot(
        workspace: workspace.displayBox.current(),
        agentDefaults: agentDefaults.displayBox.current(),
        logs: logs.displayBox.current(),
        settings: settings.displayBox.current(),
        connections: connections.displayBox.current()
      )
    }
  }
#endif

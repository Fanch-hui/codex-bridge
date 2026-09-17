#if os(Windows)
  import BridgeServiceAppCore

  struct WindowsWorkspaceEditContext {
    let projectID: String
    let commands: [BridgeWorkspaceCommandDraft]
    let blacklists: [BridgeBlacklistDraft]
    var commandID: String?
    var blacklistID: String?
  }

  extension WindowsWorkspaceModel {
    var editContext: WindowsWorkspaceEditContext? {
      guard let projectID = selectedProjectID, detail?.projectID == projectID,
        detail?.directWorkspace != nil
      else { return nil }
      return WindowsWorkspaceEditContext(
        projectID: projectID, commands: commands, blacklists: blacklists,
        commandID: selectedCommandID, blacklistID: selectedBlacklistID
      )
    }
  }
#endif

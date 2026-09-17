#if os(Windows)
  extension CodexBridgeWindowsApplication {
    static func synchronizeTaskProject(
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) {
      guard let projectID = model.selectedProjectID else { return }
      if management.selectedProjectID != projectID,
        let index = management.projects.firstIndex(where: { $0.projectID == projectID })
      {
        management.selectProject(at: index)
      }
      if auxiliary.workspace.selectedProjectID != projectID {
        auxiliary.workspace.selectProject(id: projectID)
      }
      if auxiliary.agentDefaults.workbenchProjectID != projectID {
        auxiliary.agentDefaults.workbenchProjectID = projectID
        Task { await auxiliary.agentDefaults.refreshAllProviderModels() }
      }
    }
  }
#endif

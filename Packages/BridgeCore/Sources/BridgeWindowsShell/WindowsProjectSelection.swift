#if os(Windows)
  extension WindowsWorkbenchModel {
    func selectWorkbenchProject(id: String) async {
      guard let index = projects.firstIndex(where: { $0.projectID == id }) else { return }
      await selectWorkbenchProject(at: index)
    }
  }

  extension WindowsWorkspaceModel {
    func selectProject(id: String) {
      guard let index = projects.firstIndex(where: { $0.projectID == id }) else { return }
      selectProject(at: index)
    }
  }
#endif

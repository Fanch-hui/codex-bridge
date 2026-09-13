#if os(Windows)
  import BridgeDesktopUI
  import Foundation

  extension WindowsDesktopUIStateBuilder {
    static func projectsPage(
      workbench: WindowsWorkbenchDisplay,
      management: WindowsManagementDisplay,
      workspace: WindowsWorkspaceDisplay?
    ) -> BridgeDesktopProjectsState {
      let selectedProjectID =
        management.project.selectedIndex.flatMap { index in
          management.project.projectItems.indices.contains(index)
            ? management.project.projectItems[index].projectID : nil
        } ?? workspace?.selectedProjectID
      let projectRows = management.project.projectItems
      let workspaceState: BridgeDesktopWorkspaceState?
      if let workspace, workspace.selectedProjectID == selectedProjectID, selectedProjectID != nil {
        workspaceState = BridgeDesktopWorkspaceState(
          fileWritePermission: workspace.fileWritePermission,
          commandMode: workspace.commandMode,
          commandModeOptions: workspace.commandModeValues.map {
            choice($0, workspaceModeLabel($0))
          },
          commands: workspace.commands,
          blacklist: workspace.blacklist,
          canSaveMode: workspace.saveModeEnabled,
          canSaveCommand: workspace.saveCommandEnabled,
          canRemoveCommand: workspace.removeCommandEnabled,
          canSaveBlacklist: workspace.saveBlacklistEnabled,
          canRemoveBlacklist: workspace.removeBlacklistEnabled
        )
      } else {
        workspaceState = nil
      }
      let selectedProject = projectRows.first { $0.projectID == selectedProjectID }
      return BridgeDesktopProjectsState(
        header: header(
          "项目",
          "管理项目登记、访问权限与项目资源。",
          "folder.fill"
        ),
        rows: projectRows,
        selectedProjectID: selectedProjectID,
        selectedProjectDetail: selectedProject.map { _ in management.project.detailText },
        policyOptions: policyOptions,
        readOptions: [choice("denied", "拒绝"), choice("allowed", "允许")],
        writeOptions: [
          choice("denied", "拒绝"),
          choice("requiresLocalApproval", "需要本机批准"),
          choice("allowed", "允许"),
        ],
        networkOptions: [
          choice("denied", "拒绝"),
          choice("requiresLocalApproval", "需要本机批准"),
          choice("allowed", "允许"),
        ],
        workspace: workspaceState,
        verificationCommands: workspace?.verificationCommands ?? [],
        threadCount: workspace?.threadCount,
        sessions: workbench.taskItems.filter { $0.projectID == selectedProjectID },
        threads: workspace?.threads ?? [],
        selectedThreadID: workspace?.selectedThreadID,
        selectedThreadTitle: workspace?.selectedThreadTitle,
        selectedThreadConversation: workspace?.selectedThreadConversation ?? [],
        skills: workspace?.skills ?? [],
        canRegister: management.project.registerEnabled,
        canRemove: management.project.removeEnabled,
        canSavePolicy: management.project.savePolicyEnabled
      )
    }

    private static let policyOptions = [
      choice("denied", "拒绝"),
      choice("requiresLocalApproval", "需要本机批准"),
      choice("allowed", "允许"),
    ]

    private static func workspaceModeLabel(_ mode: String) -> String {
      switch mode {
      case "denied": "禁止直接执行"
      case "safe": "安全模式"
      case "full": "完全模式"
      default: mode
      }
    }
  }
#endif

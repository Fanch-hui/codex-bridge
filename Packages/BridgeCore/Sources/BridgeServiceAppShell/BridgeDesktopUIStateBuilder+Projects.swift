import BridgeDesktopUI
import BridgeMCP

extension BridgeDesktopUIStateBuilder {
  static func projects(from model: BridgeServiceAppModel) -> BridgeDesktopProjectsState {
    let selected = model.projects.first { $0.projectID == model.selectedProjectID }
    let detail = model.selectedProjectID.flatMap { model.projectDetails[$0] }
    let projectTasks = model.tasks.filter { $0.projectID == model.selectedProjectID }
    let sessions = WorkbenchSessionCatalog.sessions(tasks: projectTasks)
      .sorted { $0.latestTask.updatedAt > $1.latestTask.updatedAt }
    return BridgeDesktopProjectsState(
      header: BridgeDesktopPageHeader(
        title: "项目",
        subtitle: "管理注册目录与项目资源。",
        symbol: BridgeServiceNavigation.projects.symbol
      ),
      rows: model.projects.map { project in
        BridgeDesktopProjectRow(
          projectID: project.projectID,
          name: project.name,
          detail: project.projectID,
          gitState: project.gitState,
          selected: project.projectID == model.selectedProjectID
        )
      },
      selectedProjectID: selected?.projectID,
      selectedProjectDetail: projectDetailText(detail),
      workspace: detail?.directWorkspace.map(workspaceState),
      verificationCommands: detail?.verificationCommands ?? [],
      threadCount: detail?.threadCount,
      sessions: sessions.map { session in
        let task = session.latestTask
        return BridgeDesktopTaskRow(
          taskID: task.taskID,
          sessionID: session.sessionID,
          title: WorkbenchTaskTextPresentation.sessionMenuTitle(
            title: session.title,
            turnCount: session.turnCount
          ),
          projectID: task.projectID,
          projectName: model.projectName(for: task.projectID),
          source: task.sourceDisplayName,
          provider: task.providerDisplayName,
          providerID: task.providerIdentifier,
          status: WorkbenchTaskTextPresentation.sessionStatusLabel(
            task.status, canContinue: canResume(task, model: model)
          ),
          updatedAt: task.updatedAt,
          turnCount: session.turnCount,
          selected: session.tasks.contains(where: { $0.taskID == model.selectedTaskID }),
          isRunning: task.isRunning,
          isActive: task.isActive,
          canDelete: session.tasks.allSatisfy { $0.isTerminal }
        )
      },
      threads: model.threads.map(threadRow),
      selectedThreadID: model.selectedThread?.thread.threadID,
      selectedThreadTitle: model.selectedThread.map { ThreadHistoryPresentation.title($0.thread) },
      selectedThreadConversation: ThreadHistoryPresentation.entries(model.selectedThread).map {
        BridgeDesktopConversationEntry(id: $0.id, role: $0.role, text: $0.text)
      },
      skills: model.skills.map(skillRow),
      canRegister: model.connectionState == .connected,
      canRemove: selected != nil && model.connectionState == .connected
    )
  }

  private static func projectDetailText(_ detail: MCPProjectDetail?) -> String? {
    guard let detail else { return nil }
    var lines = ["项目 ID：\(detail.projectID)"]
    if let gitState = ProjectAgentPresentation.gitStateLabel(detail.gitState) {
      lines.append("Git：\(gitState)")
    }
    if let count = detail.threadCount {
      lines.append("Thread：\(count)")
    }
    return lines.joined(separator: " · ")
  }

  private static func workspaceState(
    _ workspace: MCPDirectWorkspace
  ) -> BridgeDesktopWorkspaceState {
    BridgeDesktopWorkspaceState(
      commandMode: workspace.commandMode,
      commandModeOptions: BridgeDesktopProjectPresentation.workspaceCommandModeOptions,
      commands: workspace.commands.map {
        BridgeDesktopWorkspaceCommand(
          commandID: $0.commandID,
          name: $0.name,
          executable: $0.executable,
          arguments: $0.arguments,
          workingDirectory: $0.workingDirectory,
          requiresNetwork: $0.requiresNetwork,
          risk: $0.risk
        )
      },
      blacklist: workspace.commandBlacklist.map {
        BridgeDesktopBlacklistRule(
          ruleID: $0.ruleID,
          executable: $0.executable,
          pattern: $0.pattern
        )
      }
    )
  }

  private static func threadRow(_ thread: MCPThreadSummary) -> BridgeDesktopThreadRow {
    BridgeDesktopThreadRow(
      threadID: thread.threadID,
      title: ThreadHistoryPresentation.title(thread),
      status: thread.status,
      updatedAt: thread.updatedAt,
      preview: thread.preview
    )
  }

  private static func skillRow(_ skill: MCPServiceSkill) -> BridgeDesktopSkillRow {
    BridgeDesktopSkillRow(
      skillID: skill.id,
      name: skill.name,
      scope: skill.scope.rawValue,
      description: skill.description,
      actionCount: skill.actions.count,
      enabled: true
    )
  }
}

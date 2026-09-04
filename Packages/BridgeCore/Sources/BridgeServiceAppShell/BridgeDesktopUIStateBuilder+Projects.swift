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
        subtitle: "管理注册目录、访问权限、Direct 命令与只读项目资源。",
        symbol: BridgeServiceNavigation.projects.symbol
      ),
      rows: model.projects.map { project in
        BridgeDesktopProjectRow(
          projectID: project.projectID,
          name: project.name,
          detail: project.projectID,
          gitState: project.gitState,
          readPermission: project.capabilities.read,
          writePermission: project.capabilities.write,
          networkPermission: project.capabilities.network,
          selected: project.projectID == model.selectedProjectID
        )
      },
      selectedProjectID: selected?.projectID,
      selectedProjectDetail: projectDetailText(detail),
      policyOptions: policyOptions,
      readOptions: readOptions,
      writeOptions: guardedPermissionOptions,
      networkOptions: guardedPermissionOptions,
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
          status: taskStatusLabel(task.status),
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
      selectedThreadTitle: model.selectedThread.map {
        $0.thread.title ?? $0.thread.preview ?? $0.thread.threadID
      },
      selectedThreadConversation: model.selectedThread?.entries.enumerated().map { index, entry in
        BridgeDesktopConversationEntry(
          id: "thread:\(model.selectedThread?.thread.threadID ?? "history"):\(index)",
          role: entry.role == "user" ? "用户" : "Codex",
          text: entry.text
        )
      } ?? [],
      skills: model.skills.map(skillRow),
      canRegister: model.connectionState == .connected,
      canRemove: selected != nil && model.connectionState == .connected,
      canSavePolicy: selected != nil && model.connectionState == .connected
    )
  }

  private static let readOptions = [
    BridgeDesktopChoice(id: "denied", title: "拒绝"),
    BridgeDesktopChoice(id: "allowed", title: "允许"),
  ]

  private static let guardedPermissionOptions = [
    BridgeDesktopChoice(id: "denied", title: "拒绝"),
    BridgeDesktopChoice(id: "requiresLocalApproval", title: "需要本机批准"),
    BridgeDesktopChoice(id: "allowed", title: "允许"),
  ]

  private static let policyOptions = readOptions + guardedPermissionOptions.dropFirst()

  private static func projectDetailText(_ detail: MCPProjectDetail?) -> String? {
    guard let detail else { return nil }
    var lines = ["项目 ID：\(detail.projectID)"]
    if let gitState = detail.gitState, !gitState.isEmpty {
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
      fileWritePermission: workspace.fileWritePermission,
      commandMode: workspace.commandMode,
      commandModeOptions: [
        BridgeDesktopChoice(id: "denied", title: "禁止直接执行"),
        BridgeDesktopChoice(id: "safe", title: "安全模式"),
        BridgeDesktopChoice(id: "full", title: "完全模式"),
      ],
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
      title: thread.title ?? "未命名会话",
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

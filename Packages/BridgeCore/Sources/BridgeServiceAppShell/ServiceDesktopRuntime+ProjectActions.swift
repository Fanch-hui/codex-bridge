import BridgeDesktopUI
import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore
import Foundation

extension BridgeServiceAppModel {
  public func registerProject(at url: URL) {
    runMutation { [weak self] client in
      guard let self else { return }
      let detail = try await client.registerProject(
        IPCProjectRegistrationRequest(
          name: url.lastPathComponent,
          absolutePath: url.standardizedFileURL.path
        )
      )
      await self.refresh(silent: true, includeCatalog: false)
      self.selectProject(detail.projectID)
      self.postToast("已打开工作文件夹：\(url.lastPathComponent)")
    }
  }

  func loadProjectDetail(projectID: String) {
    guard let client, connectionState == .connected else { return }
    Task { [weak self] in
      do {
        let detail = try await client.projectCommands(projectID: projectID)
        self?.projectDetails[projectID] = detail
      } catch {
        self?.errorMessage = "读取项目命令配置失败。"
      }
    }
  }

  private func loadSkills(projectID: String) {
    guard let client, connectionState == .connected else { return }
    Task { [weak self] in
      do {
        let result = try await client.skills(projectID: projectID)
        guard self?.selectedProjectID == projectID else { return }
        self?.skills = result.skills
      } catch {
        self?.skills = []
      }
    }
  }

  func saveProjectCommands(
    projectID: String,
    drafts: [BridgeWorkspaceCommandDraft],
    commandBlacklist: [IPCBlacklistRule] = []
  ) {
    runMutation { [weak self] client in
      guard let self else { return }
      let commands = drafts.map { $0.toIPCCommand() }
      let detail = try await client.updateProjectCommands(
        projectID: projectID,
        commands: commands,
        commandBlacklist: commandBlacklist
      )
      self.projectDetails[projectID] = detail
      await self.refresh(silent: true, includeCatalog: false)
      self.postToast("Direct 命令配置已保存生效")
    }
  }

  func setProjectCommandMode(projectID: String, mode: String) {
    runMutation { [weak self] client in
      guard let self else { return }
      let detail = try await client.setProjectCommandMode(
        projectID: projectID,
        commandMode: mode
      )
      self.projectDetails[projectID] = detail
      await self.refresh(silent: true, includeCatalog: false)
      self.postToast("Direct 命令模式已保存")
    }
  }

  public func removeProject(_ projectID: String) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.removeProject(projectID: projectID)
      if self.selectedProjectID == projectID {
        self.selectProject(nil)
        self.threads = []
        self.skills = []
        self.selectedThread = nil
      }
      await self.refresh(silent: true, includeCatalog: false)
      self.postToast("已移除项目")
    }
  }

  public func selectProject(_ projectID: String?) {
    if selectedProjectID != projectID {
      closeConversation()
    }
    selectedProjectID = projectID
    selectedTaskID = nil
    selectedThread = nil
    selectedThreadID = nil
    threads = []
    guard let projectID else { return }
    loadProjectDetail(projectID: projectID)
    loadSkills(projectID: projectID)
  }

  /// Moves the project context to the project of an opened session while keeping that session selected.
  func alignContextProject(to projectID: String) {
    guard selectedProjectID != projectID else { return }
    selectedProjectID = projectID
    threads = []
    loadProjectDetail(projectID: projectID)
    loadSkills(projectID: projectID)
  }

  func setWorkbenchPermissionMode(_ mode: String) {
    guard let permissionMode = BridgeDesktopWorkbenchPermissionMode(rawValue: mode),
      permissionMode.rawValue != workbenchPermissionMode
    else { return }
    let mode = permissionMode.rawValue
    workbenchPermissionMode = mode
    updateWorkbenchPermissionModeState(mode)
    errorMessage = nil
    workbenchPermissionModeSyncGeneration &+= 1
    let generation = workbenchPermissionModeSyncGeneration
    let precedingTask = workbenchPermissionModeSyncTask
    workbenchPermissionModeSyncTask = Task { [weak self] in
      await precedingTask?.value
      guard let self else { return }
      do {
        let client = try self.currentClient()
        try await client.setWorkbenchPermissionMode(mode)
        self.confirmedWorkbenchPermissionMode = mode
        guard self.workbenchPermissionModeSyncGeneration == generation else { return }
        self.workbenchPermissionModeSyncTask = nil
        self.workbenchPermissionMode = mode
        self.updateWorkbenchPermissionModeState(mode)
        self.postToast(
          mode == "read-only" ? "工作台默认任务模式：只读" : "工作台默认任务模式：可写",
          symbol: "checkmark.circle.fill",
          tone: .success
        )
      } catch {
        guard self.workbenchPermissionModeSyncGeneration == generation else { return }
        self.workbenchPermissionModeSyncTask = nil
        self.workbenchPermissionMode = self.confirmedWorkbenchPermissionMode
        self.updateWorkbenchPermissionModeState(self.confirmedWorkbenchPermissionMode)
        self.errorMessage = Self.message(error)
      }
    }
  }
}

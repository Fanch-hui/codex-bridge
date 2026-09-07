#if os(Windows)
  import BridgeServiceAppCore

  extension WindowsWorkspaceModel {
    func setMode(_ mode: String, projectID requestedID: String? = nil) async {
      guard let projectID = requestedID ?? selectedProjectID, Self.modeValues.contains(mode) else {
        reportFailure("请先选择项目和有效的命令模式。")
        return
      }
      guard connectionState == .connected, !busy else { return }
      busy = true
      statusText = "正在保存命令模式…"
      publishDisplay()
      defer {
        busy = false
        publishDisplay()
      }
      do {
        let updated = try await client.setProjectCommandMode(
          projectID: projectID,
          commandMode: mode
        )
        guard selectedProjectID == projectID else { return }
        detail = updated
        syncWorkspace()
        reportSuccess("命令模式已保存。")
      } catch {
        guard selectedProjectID == projectID else { return }
        reportFailure("命令模式保存失败：\(BridgeServiceErrorMessage.message(error))")
      }
    }

    func saveCommand(
      _ draft: BridgeWorkspaceCommandDraft, context: WindowsWorkspaceEditContext? = nil
    ) async {
      guard let context = context ?? editContext else {
        reportFailure("当前项目没有可编辑的 Direct 工作区。")
        return
      }
      guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !draft.executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        reportFailure("命令名称和可执行文件不能为空。")
        return
      }
      guard connectionState == .connected, !busy else { return }
      busy = true
      statusText = "正在保存 Direct 命令…"
      publishDisplay()
      defer {
        busy = false
        publishDisplay()
      }
      let projectID = context.projectID
      var next = context.commands
      if let index = next.firstIndex(where: { $0.id == context.commandID }) {
        next[index] = draft
      } else {
        next.append(draft)
      }
      do {
        let updated = try await client.updateProjectCommands(
          projectID: projectID,
          commands: next.map { $0.toIPCCommand() },
          commandBlacklist: context.blacklists.map { $0.toIPCRule() }
        )
        guard selectedProjectID == projectID else { return }
        detail = updated
        if self.selectedCommandID == context.commandID { self.selectedCommandID = draft.id }
        syncWorkspace()
        reportSuccess("Direct 命令已保存。")
      } catch {
        guard selectedProjectID == projectID else { return }
        reportFailure("Direct 命令保存失败：\(BridgeServiceErrorMessage.message(error))")
      }
    }

    func removeSelectedCommand(context: WindowsWorkspaceEditContext? = nil) async {
      guard let context = context ?? editContext, let selectedCommandID = context.commandID
      else {
        reportFailure("请先选择要移除的命令。")
        return
      }
      guard connectionState == .connected, !busy else { return }
      busy = true
      statusText = "正在移除 Direct 命令…"
      publishDisplay()
      defer {
        busy = false
        publishDisplay()
      }
      let projectID = context.projectID
      let next = context.commands.filter { $0.id != selectedCommandID }
      do {
        let updated = try await client.updateProjectCommands(
          projectID: projectID,
          commands: next.map { $0.toIPCCommand() },
          commandBlacklist: context.blacklists.map { $0.toIPCRule() }
        )
        guard selectedProjectID == projectID else { return }
        detail = updated
        if self.selectedCommandID == selectedCommandID { self.selectedCommandID = nil }
        syncWorkspace()
        reportSuccess("Direct 命令已移除。")
      } catch {
        guard selectedProjectID == projectID else { return }
        reportFailure("Direct 命令移除失败：\(BridgeServiceErrorMessage.message(error))")
      }
    }

  }
#endif

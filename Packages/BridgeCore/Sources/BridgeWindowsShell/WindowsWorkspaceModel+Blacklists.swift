#if os(Windows)
  import BridgeServiceAppCore
  import Foundation

  extension WindowsWorkspaceModel {
    func selectBlacklist(at index: Int) {
      guard blacklists.indices.contains(index) else { return }
      selectedBlacklistID = blacklists[index].id
      publishDisplay()
    }

    func saveBlacklist(
      executable: String, pattern: String, context: WindowsWorkspaceEditContext? = nil
    ) async {
      guard let context = context ?? editContext else {
        reportFailure("当前项目没有可编辑的 Direct 工作区。")
        return
      }
      let draft = BridgeBlacklistDraft(executable: executable, pattern: pattern)
      guard
        !draft.executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || !draft.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        reportFailure("黑名单的可执行文件或参数子串至少填写一项。")
        return
      }
      guard connectionState == .connected, !busy else { return }
      busy = true
      statusText = "正在保存黑名单规则…"
      publishDisplay()
      defer {
        busy = false
        publishDisplay()
      }
      let projectID = context.projectID
      var next = context.blacklists
      if let index = next.firstIndex(where: { $0.id == context.blacklistID }) {
        next[index] = draft
      } else {
        next.append(draft)
      }
      do {
        let updated = try await client.updateProjectCommands(
          projectID: projectID,
          commands: context.commands.map { $0.toIPCCommand() },
          commandBlacklist: next.map { $0.toIPCRule() }
        )
        guard selectedProjectID == projectID else { return }
        detail = updated
        if selectedBlacklistID == context.blacklistID { selectedBlacklistID = draft.id }
        syncWorkspace()
        reportSuccess("黑名单规则已保存。")
      } catch {
        guard selectedProjectID == projectID else { return }
        reportFailure("黑名单保存失败：\(BridgeServiceErrorMessage.message(error))")
      }
    }

    func removeSelectedBlacklist(context: WindowsWorkspaceEditContext? = nil) async {
      guard let context = context ?? editContext, let selectedBlacklistID = context.blacklistID,
        connectionState == .connected, !busy
      else { return }
      busy = true
      let projectID = context.projectID
      statusText = "正在移除黑名单规则…"
      publishDisplay()
      defer {
        busy = false
        publishDisplay()
      }
      do {
        let updated = try await client.updateProjectCommands(
          projectID: projectID,
          commands: context.commands.map { $0.toIPCCommand() },
          commandBlacklist:
            context.blacklists
            .filter { $0.id != selectedBlacklistID }
            .map { $0.toIPCRule() }
        )
        guard selectedProjectID == projectID else { return }
        detail = updated
        if self.selectedBlacklistID == selectedBlacklistID { self.selectedBlacklistID = nil }
        syncWorkspace()
        reportSuccess("黑名单规则已移除。")
      } catch {
        guard selectedProjectID == projectID else { return }
        reportFailure("移除黑名单失败：\(BridgeServiceErrorMessage.message(error))")
      }
    }

    func reconcileBlacklistSelection() {
      if let selectedBlacklistID,
        blacklists.contains(where: { $0.id == selectedBlacklistID })
      {
        return
      }
      selectedBlacklistID = blacklists.first?.id
    }
  }
#endif

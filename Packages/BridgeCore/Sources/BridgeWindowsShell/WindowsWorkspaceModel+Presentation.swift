#if os(Windows)
  import BridgeDesktopUI
  import BridgeServiceAppCore

  extension WindowsWorkspaceModel {
    func publishDisplay() {
      let projectIndex = selectedProjectID.flatMap { id in
        projects.firstIndex { $0.projectID == id }
      }
      let commandIndex = selectedCommandID.flatMap { id in
        commands.firstIndex { $0.id == id }
      }
      let skillIndex = selectedSkillID.flatMap { id in
        skills.firstIndex { $0.id == id }
      }
      let threadIndex = selectedThreadID.flatMap { id in
        threads.firstIndex { $0.threadID == id }
      }
      let commandItems = commands.map(DirectWorkspacePresentation.command)
      let selectedCommand = commandIndex.flatMap { commands[$0] }
      let selectedItem = commandIndex.flatMap { commandItems[$0] }
      let skillItems = skills.map(DirectWorkspacePresentation.skill)
      let selectedSkill = skillIndex.flatMap { skillItems[$0] }
      let workspaceMode = detail?.directWorkspace?.commandMode ?? "denied"
      let hasWorkspace = detail?.directWorkspace != nil
      let blacklistIndex = selectedBlacklistID.flatMap { id in
        blacklists.firstIndex { $0.id == id }
      }
      let selectedBlacklist = blacklistIndex.flatMap { blacklists[$0] }
      let desktopCommands = commands.map { command in
        BridgeDesktopWorkspaceCommand(
          commandID: command.id,
          name: command.name,
          executable: command.executable,
          arguments: command.arguments.split(separator: "\n").map(String.init),
          workingDirectory: command.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
            ? nil : command.workingDirectory,
          requiresNetwork: command.requiresNetwork,
          risk: command.risk
        )
      }
      let desktopBlacklist = blacklists.map { rule in
        BridgeDesktopBlacklistRule(
          ruleID: rule.id,
          executable: rule.executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : rule.executable,
          pattern: rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : rule.pattern
        )
      }
      let desktopSkills = skills.map { skill in
        BridgeDesktopSkillRow(
          skillID: skill.id,
          name: skill.name,
          scope: skill.scope.rawValue,
          description: skill.description,
          actionCount: skill.actions.count
        )
      }
      let desktopThreads = threads.map { thread in
        BridgeDesktopThreadRow(
          threadID: thread.threadID,
          title: thread.title ?? thread.preview ?? thread.threadID,
          status: thread.status,
          updatedAt: thread.updatedAt,
          preview: thread.preview
        )
      }
      let value = WindowsWorkspaceDisplay(
        connectionState: connectionState,
        projectRows: projects.map { "\($0.name) · \($0.projectID)" },
        selectedProjectIndex: projectIndex,
        commandRows: commandItems.map(\.rowText),
        selectedCommandIndex: commandIndex,
        commandDetailText: selectedItem?.detailText ?? "请选择命令。",
        commandName: selectedCommand?.name ?? "",
        commandExecutable: selectedCommand?.executable ?? "",
        commandArguments: selectedCommand?.arguments ?? "",
        commandWorkingDirectory: selectedCommand?.workingDirectory ?? "",
        commandRequiresNetwork: selectedCommand?.requiresNetwork ?? false,
        commandRisk: selectedCommand?.risk ?? "normal",
        commandMode: workspaceMode,
        commandModeValues: Self.modeValues,
        skillRows: skillItems.map(\.rowText),
        selectedSkillIndex: skillIndex,
        skillDetailText: selectedSkill?.detailText
          ?? "Skills 仅支持发现和详情；当前协议没有编辑接口。",
        threadRows: threads.map { thread in
          "\(thread.title ?? thread.preview ?? thread.threadID) — \(thread.status)"
        },
        selectedThreadIndex: threadIndex,
        threadDetailText: threadDetailText(),
        blacklistRows: blacklists.map { draft in
          "\(draft.executable.isEmpty ? "任意可执行文件" : draft.executable) · \(draft.pattern.isEmpty ? "全部参数" : draft.pattern)"
        },
        selectedBlacklistIndex: blacklistIndex,
        blacklistExecutable: selectedBlacklist?.executable ?? "",
        blacklistPattern: selectedBlacklist?.pattern ?? "",
        saveCommandEnabled: connectionState == .connected && !busy && hasWorkspace,
        removeCommandEnabled: connectionState == .connected && !busy && hasWorkspace
          && selectedCommand != nil,
        saveModeEnabled: connectionState == .connected && !busy && hasWorkspace,
        saveBlacklistEnabled: connectionState == .connected && !busy && hasWorkspace,
        removeBlacklistEnabled: connectionState == .connected && !busy && selectedBlacklist != nil,
        statusText: statusText,
        selectedProjectID: selectedProjectID,
        selectedCommandID: selectedCommandID,
        selectedSkillID: selectedSkillID,
        selectedThreadID: selectedThreadID,
        fileWritePermission: detail?.directWorkspace?.fileWritePermission ?? "denied",
        commands: desktopCommands,
        blacklist: desktopBlacklist,
        skills: desktopSkills,
        threads: desktopThreads,
        verificationCommands: detail?.verificationCommands ?? [],
        threadCount: detail?.threadCount,
        selectedThreadTitle: selectedThreadPage.map {
          $0.thread.title ?? $0.thread.preview ?? $0.thread.threadID
        },
        selectedThreadConversation: selectedThreadPage?.entries.enumerated().map { index, entry in
          BridgeDesktopConversationEntry(
            id: "thread:\(selectedThreadPage?.thread.threadID ?? "history"):\(index)",
            role: entry.role == "user" ? "用户" : "Codex",
            text: entry.text
          )
        } ?? []
      )
      displayBox.store(value)
    }

    private func threadDetailText() -> String {
      guard let page = selectedThreadPage else {
        return selectedThreadID == nil ? "该项目没有 Codex Thread。" : "选择 Thread 后读取完整记录。"
      }
      let header = page.thread.title ?? page.thread.preview ?? page.thread.threadID
      guard !page.entries.isEmpty else { return "\(header)\r\n\r\n暂无可显示记录。" }
      let entries = page.entries.map { entry in
        let role = entry.role == "user" ? "用户" : (entry.role == "assistant" ? "Codex" : entry.role)
        return "\(role)：\(entry.text)"
      }.joined(separator: "\r\n\r\n")
      return "\(header)\r\n\r\n\(entries)"
    }
  }
#endif

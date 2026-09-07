#if os(Windows)
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore

  @MainActor
  final class WindowsWorkspaceModel {
    let client: any BridgeServiceClientProtocol
    let displayBox: AuxiliaryDisplayBox<WindowsWorkspaceDisplay>
    let feedback: WindowsDesktopFeedbackStore

    private(set) var connectionState: WindowsWorkbenchDisplay.ConnectionState = .idle
    private(set) var projects: [MCPProjectSummary] = []
    var detail: MCPProjectDetail?
    private(set) var commands: [BridgeWorkspaceCommandDraft] = []
    private(set) var skills: [MCPServiceSkill] = []
    var threads: [MCPThreadSummary] = []
    var selectedThreadPage: MCPThreadReadPage?
    var blacklists: [BridgeBlacklistDraft] = []
    var selectedProjectID: String?
    var selectedCommandID: String?
    var selectedSkillID: String?
    var selectedThreadID: String?
    var selectedBlacklistID: String?
    var busy = false
    var statusText = "尚未加载项目工作区。"

    init(
      client: any BridgeServiceClientProtocol,
      feedback: WindowsDesktopFeedbackStore
    ) {
      self.client = client
      self.feedback = feedback
      displayBox = AuxiliaryDisplayBox(
        value: WindowsWorkspaceDisplay(
          connectionState: .idle,
          projectRows: [],
          selectedProjectIndex: nil,
          commandRows: [],
          selectedCommandIndex: nil,
          commandDetailText: "请选择项目和命令。",
          commandName: "",
          commandExecutable: "",
          commandArguments: "",
          commandWorkingDirectory: "",
          commandRequiresNetwork: false,
          commandRisk: "normal",
          commandMode: "denied",
          commandModeValues: Self.modeValues,
          skillRows: [],
          selectedSkillIndex: nil,
          skillDetailText: "Skills 仅支持发现和详情；当前协议没有编辑接口。",
          threadRows: [],
          selectedThreadIndex: nil,
          threadDetailText: "请选择 Codex Thread。",
          blacklistRows: [],
          selectedBlacklistIndex: nil,
          blacklistExecutable: "",
          blacklistPattern: "",
          saveCommandEnabled: false,
          removeCommandEnabled: false,
          saveModeEnabled: false,
          saveBlacklistEnabled: false,
          removeBlacklistEnabled: false,
          statusText: statusText
        )
      )
    }

    static let modeValues = ["denied", "safe", "full"]
    static let riskValues = ["normal", "elevated"]

    func refresh() async {
      guard !busy else { return }
      busy = true
      statusText = "正在读取项目工作区…"
      publishDisplay()
      defer {
        busy = false
        publishDisplay()
      }
      do {
        let status = try await client.status()
        connectionState = .connected
        projects = try await client.projects()
        if projects.contains(where: { $0.projectID == status.workbenchProjectID }) {
          selectedProjectID = status.workbenchProjectID
        }
        reconcileProjectSelection()
        await loadSelectedWorkspace()
      } catch {
        statusText = "项目工作区读取失败：\(BridgeServiceErrorMessage.message(error))"
        publishDisplay()
      }
    }

    func selectProject(at index: Int) {
      guard projects.indices.contains(index) else { return }
      selectedProjectID = projects[index].projectID
      selectedCommandID = nil
      selectedSkillID = nil
      selectedThreadID = nil
      selectedThreadPage = nil
      selectedBlacklistID = nil
      detail = nil
      commands = []
      skills = []
      threads = []
      blacklists = []
      statusText = "已选择项目：\(projects[index].name)"
      publishDisplay()
      Task { await loadSelectedWorkspace() }
    }

    func selectCommand(at index: Int) {
      guard commands.indices.contains(index) else { return }
      selectedCommandID = commands[index].id
      publishDisplay()
    }

    func selectSkill(at index: Int) {
      guard skills.indices.contains(index) else { return }
      selectedSkillID = skills[index].id
      publishDisplay()
    }

    func loadSelectedWorkspace() async {
      guard let projectID = selectedProjectID else {
        detail = nil
        commands = []
        skills = []
        threads = []
        blacklists = []
        selectedThreadPage = nil
        publishDisplay()
        return
      }
      do {
        let loadedDetail = try await client.projectCommands(projectID: projectID)
        let loadedSkills: [MCPServiceSkill]
        do {
          loadedSkills = try await client.skills(projectID: projectID).skills
        } catch {
          loadedSkills = []
        }
        let loadedThreads =
          (try? await client.threads(
            IPCThreadListRequest(projectID: projectID)
          ).threads) ?? []
        guard selectedProjectID == projectID else { return }
        detail = loadedDetail
        skills = loadedSkills
        threads = loadedThreads
        syncWorkspace()
        reconcileSkillSelection()
        reconcileThreadSelection()
        statusText = "已加载 Direct、\(loadedSkills.count) 个 Skills 和 \(loadedThreads.count) 个 Threads。"
      } catch {
        guard selectedProjectID == projectID else { return }
        statusText = "命令读取失败：\(BridgeServiceErrorMessage.message(error))"
      }
      publishDisplay()
    }

    func syncWorkspace() {
      guard let workspace = detail?.directWorkspace else {
        commands = []
        blacklists = []
        selectedCommandID = nil
        selectedBlacklistID = nil
        return
      }
      commands = workspace.commands.map(BridgeWorkspaceCommandDraft.init)
      blacklists = workspace.commandBlacklist.map(BridgeBlacklistDraft.init)
      reconcileCommandSelection()
      reconcileBlacklistSelection()
    }

    private func reconcileProjectSelection() {
      if let selectedProjectID, projects.contains(where: { $0.projectID == selectedProjectID }) {
        return
      }
      selectedProjectID = projects.first?.projectID
    }

    private func reconcileCommandSelection() {
      if let selectedCommandID, commands.contains(where: { $0.id == selectedCommandID }) {
        return
      }
      selectedCommandID = commands.first?.id
    }

    private func reconcileSkillSelection() {
      if let selectedSkillID, skills.contains(where: { $0.id == selectedSkillID }) { return }
      selectedSkillID = skills.first?.id
    }

  }
#endif

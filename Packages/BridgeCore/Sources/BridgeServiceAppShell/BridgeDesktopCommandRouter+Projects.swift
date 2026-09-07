import AppKit
import BridgeDesktopUI
import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore

extension BridgeDesktopCommandRouter {
  static func handleProjects(
    _ envelope: BridgeDesktopCommandEnvelope,
    model: BridgeServiceAppModel
  ) {
    let payload = envelope.payload
    switch envelope.command {
    case .selectProject:
      guard connected(model) else { return }
      guard let projectID = validatedID(payload.projectID), project(projectID, in: model) != nil
      else { return }
      model.selectProject(projectID)
    case .refreshProjects:
      model.refresh()
    case .registerProject:
      guard connected(model) else { return }
      chooseProject(model: model)
    case .removeProject:
      guard connected(model), let projectID = validatedID(payload.projectID),
        project(projectID, in: model) != nil
      else { return }
      model.removeProject(projectID)
    case .saveProjectPolicy:
      savePolicy(payload, model: model)
    case .setProjectCommandMode:
      guard connected(model), let projectID = validatedID(payload.projectID),
        project(projectID, in: model) != nil,
        let mode = validatedID(payload.mode, maximumBytes: 32),
        ["denied", "safe", "full"].contains(mode)
      else { return }
      model.setProjectCommandMode(projectID: projectID, mode: mode)
    case .saveProjectCommand:
      saveCommand(payload, model: model)
    case .removeProjectCommand:
      removeCommand(payload, model: model)
    case .saveProjectBlacklist:
      saveBlacklist(payload, model: model)
    case .removeProjectBlacklist:
      removeBlacklist(payload, model: model)
    case .openThread:
      openThread(payload, model: model)
    default:
      return
    }
  }

  private static func chooseProject(model: BridgeServiceAppModel) {
    let panel = NSOpenPanel()
    panel.title = "选择要注册的项目目录"
    panel.prompt = "注册"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.registerProject(at: url)
  }

  private static func savePolicy(
    _ payload: BridgeDesktopCommandPayload,
    model: BridgeServiceAppModel
  ) {
    guard connected(model), let projectID = validatedID(payload.projectID),
      project(projectID, in: model) != nil,
      let read = validatedPermission(payload.readPermission, readOnly: true),
      let write = validatedPermission(payload.writePermission, readOnly: false),
      let network = validatedPermission(payload.networkPermission, readOnly: false)
    else { return }
    model.updateProjectPolicy(
      projectID: projectID,
      draft: BridgeProjectPolicyDraft(
        readPermission: read,
        writePermission: write,
        networkPermission: network
      )
    )
  }

  private static func validatedPermission(
    _ value: String?,
    readOnly: Bool
  ) -> String? {
    guard let value = validatedID(value, maximumBytes: 64) else { return nil }
    let allowed =
      readOnly
      ? ["denied", "allowed"]
      : ["denied", "requiresLocalApproval", "allowed"]
    return allowed.contains(value) ? value : nil
  }

  private static func saveCommand(
    _ payload: BridgeDesktopCommandPayload,
    model: BridgeServiceAppModel
  ) {
    guard connected(model), let projectID = validatedID(payload.projectID),
      project(projectID, in: model) != nil,
      let workspace = model.projectDetails[projectID]?.directWorkspace,
      let name = validatedID(payload.name, maximumBytes: 256),
      let executable = validatedText(payload.executable, maximumBytes: 4_096),
      !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let risk = validatedID(payload.risk ?? "normal", maximumBytes: 64),
      let arguments = commandArguments(payload.arguments ?? [], maximum: 128)
    else { return }
    let commandID = validatedID(payload.commandID, maximumBytes: 256)
    let existing = commandID.flatMap { id in
      workspace.commands.first { $0.commandID == id }
    }
    guard commandID == nil || existing != nil else { return }
    let draft = BridgeWorkspaceCommandDraft(
      name: name,
      executable: executable,
      arguments: arguments.joined(separator: "\n"),
      workingDirectory: validatedWorkingDirectory(payload.workingDirectory),
      requiresNetwork: payload.requiresNetwork ?? false,
      risk: risk
    )
    var drafts = workspace.commands.map(BridgeWorkspaceCommandDraft.init)
    if let commandID,
      let index = workspace.commands.firstIndex(where: { $0.commandID == commandID })
    {
      drafts[index] = draft
    } else {
      drafts.append(draft)
    }
    saveWorkspace(
      projectID: projectID,
      drafts: drafts,
      blacklist: workspace.commandBlacklist,
      model: model
    )
  }

  private static func commandArguments(
    _ values: [String],
    maximum: Int
  ) -> [String]? {
    guard values.count <= maximum else { return nil }
    guard values.allSatisfy({ $0.utf8.count <= 4_096 && !$0.contains("\0") }) else {
      return nil
    }
    return values
  }

  private static func validatedWorkingDirectory(_ value: String?) -> String {
    guard let value = validatedText(value, maximumBytes: 4_096) else { return "" }
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func removeCommand(
    _ payload: BridgeDesktopCommandPayload,
    model: BridgeServiceAppModel
  ) {
    guard connected(model), let projectID = validatedID(payload.projectID),
      let commandID = validatedID(payload.commandID, maximumBytes: 256),
      let workspace = model.projectDetails[projectID]?.directWorkspace,
      workspace.commands.contains(where: { $0.commandID == commandID })
    else { return }
    let drafts = workspace.commands
      .filter { $0.commandID != commandID }
      .map(BridgeWorkspaceCommandDraft.init)
    saveWorkspace(
      projectID: projectID,
      drafts: drafts,
      blacklist: workspace.commandBlacklist,
      model: model
    )
  }

  private static func saveWorkspace(
    projectID: String,
    drafts: [BridgeWorkspaceCommandDraft],
    blacklist: [MCPCommandBlacklistRule],
    model: BridgeServiceAppModel
  ) {
    model.saveProjectCommands(
      projectID: projectID,
      drafts: drafts,
      commandBlacklist: blacklist.map {
        IPCBlacklistRule(ruleID: $0.ruleID, executable: $0.executable, pattern: $0.pattern)
      }
    )
  }

  private static func saveBlacklist(
    _ payload: BridgeDesktopCommandPayload,
    model: BridgeServiceAppModel
  ) {
    guard connected(model), let projectID = validatedID(payload.projectID),
      let workspace = model.projectDetails[projectID]?.directWorkspace,
      let rule = blacklistRule(payload)
    else { return }
    let ruleID = validatedID(payload.ruleID, maximumBytes: 256)
    guard
      payload.ruleID == nil
        || workspace.commandBlacklist.contains(where: { $0.ruleID == ruleID })
    else { return }
    var rules = workspace.commandBlacklist
    if let index = rules.firstIndex(where: { $0.ruleID == ruleID }) {
      rules[index] = rule
    } else {
      rules.append(rule)
    }
    saveWorkspace(
      projectID: projectID,
      drafts: workspace.commands.map(BridgeWorkspaceCommandDraft.init),
      blacklist: rules,
      model: model
    )
  }

  private static func blacklistRule(
    _ payload: BridgeDesktopCommandPayload
  ) -> MCPCommandBlacklistRule? {
    let executable = validatedText(payload.executable, maximumBytes: 4_096)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let pattern = validatedText(payload.pattern, maximumBytes: 4_096)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !(executable ?? "").isEmpty || !(pattern ?? "").isEmpty else { return nil }
    let draft = BridgeBlacklistDraft(
      executable: executable ?? "",
      pattern: pattern ?? ""
    )
    let rule = draft.toIPCRule()
    return MCPCommandBlacklistRule(
      ruleID: rule.ruleID,
      executable: rule.executable,
      pattern: rule.pattern
    )
  }

  private static func removeBlacklist(
    _ payload: BridgeDesktopCommandPayload,
    model: BridgeServiceAppModel
  ) {
    guard connected(model), let projectID = validatedID(payload.projectID),
      let ruleID = validatedID(payload.ruleID, maximumBytes: 256),
      let workspace = model.projectDetails[projectID]?.directWorkspace,
      workspace.commandBlacklist.contains(where: { $0.ruleID == ruleID })
    else { return }
    let rules = workspace.commandBlacklist.filter { $0.ruleID != ruleID }
    saveWorkspace(
      projectID: projectID,
      drafts: workspace.commands.map(BridgeWorkspaceCommandDraft.init),
      blacklist: rules,
      model: model
    )
  }

  private static func openThread(
    _ payload: BridgeDesktopCommandPayload,
    model: BridgeServiceAppModel
  ) {
    guard connected(model), let threadID = validatedID(payload.threadID),
      model.threads.contains(where: { $0.threadID == threadID })
    else { return }
    let projectID = validatedID(payload.projectID)
    if let projectID, project(projectID, in: model) == nil { return }
    model.openThread(threadID, inProject: projectID)
    model.selection = .workbench
  }
}

import MCP

public enum MCPServiceToolName: String, CaseIterable, Sendable {
  case bridgeStatus = "bridge_status"
  case listProjects = "list_projects"
  case listAgents = "list_agents"
  case getProject = "get_project"
  case searchProjectFiles = "search_project_files"
  case listProjectDirectory = "list_project_directory"
  case batchReadProjectFiles = "batch_read_project_files"
  case readProjectFile = "read_project_file"
  case listThreads = "list_threads"
  case readThread = "read_thread"
  case listAgentNativeSessions = "list_agent_native_sessions"
  case readAgentNativeSession = "read_agent_native_session"
  case indexAgentNativeSession = "index_agent_native_session"
  case renameAgentNativeSession = "rename_agent_native_session"
  case deleteAgentNativeSession = "delete_agent_native_session"
  case listModels = "list_models"
  case listSkills = "list_skills"
  case readSkill = "read_skill"
  case runSkillAction = "run_skill_action"
  case listTasks = "list_tasks"
  case getTask = "get_task"
  case answerUserInput = "answer_user_input"
  case submitTask = "submit_task"
  case steerTask = "steer_task"
  case interruptTask = "interrupt_task"
  case getProjectChanges = "get_project_changes"
  case listProjectCommands = "list_project_commands"
  case directWriteProjectFile = "direct_write_project_file"
  case directEditProjectFile = "direct_edit_project_file"
  case directApplyProjectPatch = "direct_apply_project_patch"
  case directManageProjectPath = "direct_manage_project_path"
  case directPreviewProjectMutation = "direct_preview_project_mutation"
  case directApplyProjectMutation = "direct_apply_project_mutation"
  case directUndoProjectMutation = "direct_undo_project_mutation"
  case directExecCommand = "direct_exec_project_command"
  case listDirectCommands = "list_direct_commands"
  case directReadCommand = "direct_read_command"
  case directWriteStdin = "direct_write_stdin"
  case directInterruptCommand = "direct_interrupt_command"
  case directGitCommit = "direct_git_commit"
}

enum MCPServiceToolRoute: Sendable {
  case readOnly
  case task
  case direct
  case nativeSessionDirectory
}

struct MCPServiceToolContract: Sendable {
  let name: MCPServiceToolName
  let definition: Tool
  let minimumExposure: MCPServiceExposureMode
  let route: MCPServiceToolRoute

  func isExposed(in mode: MCPServiceExposureMode) -> Bool {
    minimumExposure == .readOnly || mode == .full
  }
}

public struct MCPServiceToolCatalog: Sendable {
  public static let contractVersion = "1.3.0"

  public let definitions: [Tool]

  public init(exposureMode: MCPServiceExposureMode) {
    definitions = Self.contracts
      .filter { $0.isExposed(in: exposureMode) }
      .map(\.definition)
  }

  static func contract(named rawName: String) -> MCPServiceToolContract? {
    contractsByName[rawName]
  }

  private static let contractsByName: [String: MCPServiceToolContract] = {
    let pairs = contracts.map { ($0.name.rawValue, $0) }
    precondition(Set(pairs.map(\.0)).count == pairs.count)
    precondition(pairs.allSatisfy { $0.0 == $0.1.definition.name })
    return Dictionary(uniqueKeysWithValues: pairs)
  }()

  private static let contracts: [MCPServiceToolContract] = [
    contract(.bridgeStatus, bridgeStatus, exposure: .readOnly, route: .readOnly),
    contract(.listProjects, listProjects, exposure: .readOnly, route: .readOnly),
    contract(.listAgents, listAgents, exposure: .readOnly, route: .readOnly),
    contract(.getProject, getProject, exposure: .readOnly, route: .readOnly),
    contract(.searchProjectFiles, searchProjectFiles, exposure: .readOnly, route: .readOnly),
    contract(.listProjectDirectory, listProjectDirectory, exposure: .readOnly, route: .readOnly),
    contract(.batchReadProjectFiles, batchReadProjectFiles, exposure: .readOnly, route: .readOnly),
    contract(.readProjectFile, readProjectFile, exposure: .readOnly, route: .readOnly),
    contract(.listThreads, listThreads, exposure: .readOnly, route: .readOnly),
    contract(.readThread, readThread, exposure: .readOnly, route: .readOnly),
    contract(
      .listAgentNativeSessions, listAgentNativeSessions, exposure: .readOnly, route: .readOnly),
    contract(
      .readAgentNativeSession, readAgentNativeSession, exposure: .readOnly, route: .readOnly),
    contract(.listModels, listModels, exposure: .readOnly, route: .readOnly),
    contract(.listSkills, listSkills, exposure: .readOnly, route: .readOnly),
    contract(.readSkill, readSkill, exposure: .readOnly, route: .readOnly),
    contract(.listTasks, listTasks, exposure: .readOnly, route: .task),
    contract(.getTask, getTask, exposure: .readOnly, route: .task),
    contract(.getProjectChanges, getProjectChanges, exposure: .readOnly, route: .readOnly),
    contract(.listProjectCommands, listProjectCommands, exposure: .readOnly, route: .readOnly),
    contract(
      .indexAgentNativeSession, indexAgentNativeSession, exposure: .full,
      route: .nativeSessionDirectory),
    contract(
      .renameAgentNativeSession, renameAgentNativeSession, exposure: .full,
      route: .nativeSessionDirectory),
    contract(
      .deleteAgentNativeSession, deleteAgentNativeSession, exposure: .full,
      route: .nativeSessionDirectory),
    contract(.answerUserInput, answerUserInput, exposure: .full, route: .task),
    contract(.submitTask, submitTask, exposure: .full, route: .task),
    contract(.runSkillAction, runSkillAction, exposure: .full, route: .task),
    contract(.steerTask, steerTask, exposure: .full, route: .task),
    contract(.interruptTask, interruptTask, exposure: .full, route: .task),
    contract(.directWriteProjectFile, directWriteProjectFile, exposure: .full, route: .direct),
    contract(.directEditProjectFile, directEditProjectFile, exposure: .full, route: .direct),
    contract(.directApplyProjectPatch, directApplyProjectPatch, exposure: .full, route: .direct),
    contract(.directManageProjectPath, directManageProjectPath, exposure: .full, route: .direct),
    contract(
      .directPreviewProjectMutation, directPreviewProjectMutation, exposure: .full, route: .direct),
    contract(
      .directApplyProjectMutation, directApplyProjectMutation, exposure: .full, route: .direct),
    contract(
      .directUndoProjectMutation, directUndoProjectMutation, exposure: .full, route: .direct),
    contract(.directExecCommand, directExecProjectCommand, exposure: .full, route: .direct),
    contract(.listDirectCommands, listDirectCommands, exposure: .full, route: .direct),
    contract(.directReadCommand, directReadCommand, exposure: .full, route: .direct),
    contract(.directWriteStdin, directWriteStdin, exposure: .full, route: .direct),
    contract(.directInterruptCommand, directInterruptCommand, exposure: .full, route: .direct),
    contract(.directGitCommit, directGitCommit, exposure: .full, route: .direct),
  ]

  private static func contract(
    _ name: MCPServiceToolName,
    _ definition: Tool,
    exposure: MCPServiceExposureMode,
    route: MCPServiceToolRoute
  ) -> MCPServiceToolContract {
    MCPServiceToolContract(
      name: name,
      definition: definition,
      minimumExposure: exposure,
      route: route
    )
  }
}

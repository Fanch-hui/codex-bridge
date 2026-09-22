import AppKit
import BridgeDesktopUI
import BridgeMCP
import Foundation

@MainActor
enum BridgeDesktopCommandRouter {
  static func handle(
    _ envelope: BridgeDesktopCommandEnvelope,
    model: BridgeServiceAppModel
  ) {
    switch envelope.command {
    case .checkAppUpdate:
      model.appUpdater.check()
    case .installAppUpdate:
      model.appUpdater.install()
    case .deferAppUpdate:
      model.appUpdater.deferUpdate()
    case .saveDirectConfiguration:
      model.saveDirectConfiguration(envelope.payload.value)
    case .openExternalURL:
      guard let url = BridgeDesktopExternalURL.resolve(envelope.payload.value) else { return }
      NSWorkspace.shared.open(url)
    case .copyTunnelID:
      guard let id = model.serviceStatus?.tunnel.tunnelID, !id.isEmpty else { return }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(id, forType: .string)
      model.postToast("已复制 Tunnel ID", symbol: "doc.on.doc")
    case .ready, .requestStateResync:
      return
    case .refresh:
      model.refresh()
    case .refreshModels:
      model.refreshModels()
    case .setCodexExecutable:
      guard let path = envelope.payload.path, path.utf8.count <= 16 * 1_024, !path.contains("\0")
      else { return }
      model.setCodexExecutablePath(path.trimmingCharacters(in: .whitespacesAndNewlines))
    case .scanAgents:
      model.scanAgents()
    case .selectPage:
      guard let navigation = envelope.payload.navigation else { return }
      select(navigation, model: model)
    case .openWorkbench:
      model.selection = .workbench
    case .openProjects:
      model.selection = .projects
    case .openConnections:
      model.selection = .connections
    case .openSettings:
      model.selection = .settings
      loadNativePermissionPolicyIfNeeded(model)
    case .openLogs:
      model.selection = .logs
    case .openSystemSettings:
      model.openSystemSettings()
    case .openTask:
      guard let taskID = validatedID(envelope.payload.taskID),
        model.tasks.contains(where: { $0.taskID == taskID })
      else { return }
      model.openTask(taskID)
      model.selection = .workbench
    case .browserBack, .browserForward, .browserReload, .setBrowserEnabled,
      .openBrowserExternally, .loadEarlierConversation, .refreshConversation,
      .setWorkbenchPermissionMode, .selectTask, .refreshTasks, .interruptTask,
      .stopTask, .deleteTask, .deleteSession, .steerTask, .resumeTask, .restartTask, .handoffTask,
      .resolveApproval, .resolveDirectApproval:
      handleWorkbench(envelope, model: model)
    case .selectProject, .refreshProjects, .registerProject, .removeProject,
      .saveProjectPolicy, .setProjectCommandMode, .saveProjectCommand,
      .removeProjectCommand, .saveProjectBlacklist, .removeProjectBlacklist, .openThread:
      handleProjects(envelope, model: model)
    case .selectLog, .refreshLogs, .setLogSearch, .setLogProjectFilter,
      .setLogKindFilter, .copyLogs:
      handleLogs(envelope, model: model)
    case .setMCPClientEnabled, .setMCPClientExposure, .copyMCPClientConfiguration,
      .copyLocalMCPEndpoint,
      .rotateMCPClientCredential, .rotateLocalMCPEndpoint,
      .saveDeepSeekHarnessMCPServer, .deleteDeepSeekHarnessMCPServer,
      .setDeepSeekHarnessMCPServerEnabled, .configureTunnel,
      .connectTunnel, .disconnectTunnel, .clearTunnel, .connectAgent, .registerAgent,
      .beginAgentRegistration,
      .selectAgent,
      .setAgentEnabled, .reprobeAgent, .removeAgent, .refreshAgentModels:
      handleConnections(envelope, model: model)
    case .refreshAgentNativePermission, .setAgentNativePermissionMode,
      .addAgentNativePermissionRule, .replaceAgentNativePermissionRule,
      .removeAgentNativePermissionRule, .prepareAgentPermissionRemediation,
      .applyAgentPermissionRemediation:
      handleNativePermissions(envelope, model: model)
    case .saveAgentDefault, .setExecutionModel, .setExecutionEffort, .setAccessMode,
      .setFastMode,
      .setDirectApprovalMode, .setTaskStartApprovalMode, .saveSettings,
      .saveCustomInstructions, .registerService, .unregisterService,
      .setKeepServiceRunning, .updateBrowserViewport:
      handleSettings(envelope, model: model)
    case .dismissFeedback:
      return
    }
  }

  static func select(
    _ navigation: BridgeDesktopNavigation,
    model: BridgeServiceAppModel
  ) {
    guard let selection = BridgeServiceNavigation(rawValue: navigation.rawValue) else { return }
    model.selection = selection
    if selection == .settings { loadNativePermissionPolicyIfNeeded(model) }
  }

  static func validatedID(_ value: String?, maximumBytes: Int = 1_024) -> String? {
    guard let value else { return nil }
    let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !result.isEmpty, result.utf8.count <= maximumBytes, !result.contains("\0") else {
      return nil
    }
    return result
  }

  static func validatedText(_ value: String?, maximumBytes: Int) -> String? {
    guard let value, value.utf8.count <= maximumBytes, !value.contains("\0") else { return nil }
    return value
  }

  static func connected(_ model: BridgeServiceAppModel) -> Bool {
    model.connectionState == .connected
  }

  static func project(
    _ projectID: String?,
    in model: BridgeServiceAppModel
  ) -> MCPProjectSummary? {
    guard let projectID = validatedID(projectID) else { return nil }
    return model.projects.first { $0.projectID == projectID }
  }

  static func panelURL(_ path: String?, directory: Bool = false) -> URL? {
    guard let path = validatedText(path, maximumBytes: 4_096),
      !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      path.hasPrefix("/")
    else { return nil }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    if directory {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else { return nil }
    }
    return url
  }
}

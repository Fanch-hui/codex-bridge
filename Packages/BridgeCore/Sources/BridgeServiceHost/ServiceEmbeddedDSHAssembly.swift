import BridgeAgentCore
import BridgeCodexService
import BridgeDeepSeekHarnessDesktop
import BridgeDomain
import BridgeFiles
import BridgeSecurity
import BridgeServiceApplication
import BridgeServiceCore
import Foundation

enum ServiceEmbeddedDSHAssembly {
  static func workspaceResolver(store: SimpleServiceStore, workspaces: AgentWorkspaceStore)
    -> ServiceExecutionWorkspaceResolver
  {
    { task, project in
      guard task.source == .mcpClient, task.sourceClientID.hasPrefix("embedded.dsh."),
        task.permissionMode == .full
      else { return nil }
      guard
        try await store.setting(
          key: "embedded_dsh.workspace.active." + task.sourceClientID)?.value == "isolated"
      else { return nil }
      guard let snapshot = try await workspaces.snapshot(id: task.sourceClientID) else {
        throw ExecutionServiceError.invalidRequest("isolatedWorkspace.missing")
      }
      try project.root.validateCurrentIdentity()
      guard
        project.root.identifies(
          canonicalPath: snapshot.projectRoot.canonicalPath,
          device: snapshot.projectRoot.identity.device, inode: snapshot.projectRoot.identity.inode)
      else { throw ExecutionServiceError.projectIdentityChanged(project.id) }
      return ServiceExecutionWorkspace(
        root: snapshot.workspaceRoot, runtimeRoot: snapshot.runtimeRoot)
    }
  }

  static func make(
    application: BridgeServiceApplication,
    projects: ServiceProjectService,
    tasks: ServiceTaskManager,
    store: SimpleServiceStore,
    settings: ServiceSettings,
    registry: ServiceAgentRegistry,
    providers: [any AgentProvider],
    desktop: DeepSeekHarnessDesktopController,
    secretStore: any SecretStore,
    dataRoot: URL,
    workspaces: AgentWorkspaceStore
  ) -> ServiceEmbeddedDSHController {
    ServiceEmbeddedDSHController(
      application: application, projects: projects, store: store, settings: settings,
      secretStore: secretStore, dataRoot: dataRoot,
      workspaces: workspaces,
      externalWorkspaceReadiness: { providerID, installationID, snapshot, runtimeDirectory in
        let id = AgentProviderID(rawValue: providerID)
        guard
          let provider = providers.first(where: { $0.descriptor.providerID == id })
            as? any AgentWorkspaceIsolationProviding
        else {
          return AgentWorkspaceIsolationReadiness(
            ready: false, reason: "该执行器尚未启用进程写入隔离。")
        }
        let record = try await registry.reprobe(
          installationID: AgentInstallationID(rawValue: installationID),
          acceptReplacement: false, projectRoot: snapshot.projectRoot.canonicalPath)
        guard record.isSelectable, record.providerID == id else {
          throw AgentRuntimeError.installationUnavailable(
            AgentInstallationID(rawValue: installationID))
        }
        return try await provider.isolatedWorkspaceReadiness(
          installation: try record.agentInstallation(),
          workspaceRoot: snapshot.workspaceRoot.canonicalPath,
          runtimeDirectory: runtimeDirectory)
      },
      externalChildRecovery: { child in
        guard child.providerID == AgentProviderID.deepSeekHarnessDesktop.rawValue,
          let taskID = child.currentTaskID, let installationID = child.installationID,
          let task = try await tasks.task(id: taskID), task.projectID == child.projectID,
          let runtime = try await tasks.agentRuntimeBinding(taskID: taskID),
          runtime.connectionMode == .nativeDesktop,
          let project = try await projects.project(id: child.projectID)
        else { throw ServiceStoreError.invalidArgument("embedded_dsh.recovery_binding") }
        try project.root.validateCurrentIdentity()
        let record = try await registry.validateForRuntimeBinding(
          installationID: AgentInstallationID(rawValue: installationID),
          projectRoot: project.root.canonicalPath, runtimeBinding: runtime)
        let result = try await desktop.reconcileRun(
          installation: record.agentInstallation(), runtime: runtime,
          sessionID: child.nativeSessionID, projectRoot: project.root.canonicalPath)
        switch result {
        case .completed(let summary):
          return .completed(resultSummary: summary, changedFiles: task.state.changedFiles)
        case .failed(let code, let summary):
          return .failed(failureCode: code, summary: summary)
        case .interrupted:
          return .interrupted(summary: "原 DSH Desktop 请求已确认结束。")
        }
      })
  }
}

import BridgeAgentCore
import BridgeDeepSeekHarnessDesktop
import BridgeDomain
import BridgeSecurity
import BridgeServiceApplication
import BridgeServiceCore
import Foundation

enum ServiceEmbeddedDSHAssembly {
  static func make(
    application: BridgeServiceApplication,
    projects: ServiceProjectService,
    tasks: ServiceTaskManager,
    store: SimpleServiceStore,
    registry: ServiceAgentRegistry,
    desktop: DeepSeekHarnessDesktopController,
    secretStore: any SecretStore,
    dataRoot: URL
  ) -> ServiceEmbeddedDSHController {
    ServiceEmbeddedDSHController(
      application: application, projects: projects, store: store,
      secretStore: secretStore, dataRoot: dataRoot,
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

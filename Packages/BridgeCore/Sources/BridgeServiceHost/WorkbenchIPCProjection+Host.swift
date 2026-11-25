import BridgeAgentCore
import BridgeCodexService
import BridgeDomain
import BridgeFiles
import BridgeSecurity
import BridgeServiceApplication
import BridgeServiceCore
import BridgeWorkbenchService
import Foundation

extension WorkbenchIPCProjection {
  static let host = WorkbenchIPCProjection(
    mapError: BridgeServiceRequestController.map,
    approvalSummary: BridgeServiceRequestController.approvalSummary,
    conversationPage: BridgeServiceRequestController.conversationPage(taskID:entries:))
}

extension ServiceEmbeddedDSHController {
  public init(
    application: BridgeServiceApplication,
    projects: ServiceProjectService,
    store: SimpleServiceStore,
    settings: ServiceSettings? = nil,
    secretStore: any SecretStore,
    dataRoot: URL,
    resourceRoot: URL? = nil,
    workspaces: AgentWorkspaceStore? = nil,
    externalWorkspaceReadiness:
      @escaping @Sendable (String, String, AgentWorkspaceSnapshot, String) async throws
      -> AgentWorkspaceIsolationReadiness = { _, _, _, _ in
        AgentWorkspaceIsolationReadiness(ready: false, reason: "该执行器尚未启用进程写入隔离。")
      },
    externalWorkspaceSupport: @escaping @Sendable (String) -> String? = { _ in nil },
    externalChildRecovery:
      @escaping @Sendable (EmbeddedDSHSubagentBinding) async throws -> EmbeddedDSHReconciledOutcome? =
      {
        _ in nil
      }
  ) {
    self.init(
      application: application, projects: projects, store: store, settings: settings,
      secretStore: secretStore, dataRoot: dataRoot, resourceRoot: resourceRoot,
      workspaces: workspaces, ipcProjection: .host,
      externalWorkspaceReadiness: externalWorkspaceReadiness,
      externalWorkspaceSupport: externalWorkspaceSupport,
      externalChildRecovery: externalChildRecovery)
  }
}

#if os(Windows)
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore
  import Foundation
  import XCTest

  @testable import BridgeWindowsShell

  final class WindowsCommandTargetTests: XCTestCase {
    func testQueuedApprovalCommandsKeepTheirOwnTargets() async {
      let observed = expectation(description: "Both approval requests arrive")
      observed.expectedFulfillmentCount = 2
      let backend = CommandTargetBackend(approvalObserved: observed)
      let client = BridgeServiceClient(transport: CommandTargetTransport(backend: backend))
      let model = await MainActor.run {
        WindowsWorkbenchModel(client: client, feedback: WindowsDesktopFeedbackStore())
      }
      await model.loadTasks()
      await MainActor.run {
        let feedback = WindowsDesktopFeedbackStore()
        let management = WindowsManagementModel(client: client, feedback: feedback)
        let auxiliary = WindowsAuxiliaryRuntime(client: client, feedback: feedback)
        model.approvals = ["a", "b"].map {
          IPCApprovalSummary(
            approvalID: $0, taskID: "task-\($0)", threadID: "thread-\($0)",
            turnID: "turn-\($0)", itemID: "item-\($0)", kind: "command", title: $0, summary: $0
          )
        }
        for id in ["a", "b"] {
          XCTAssertTrue(
            CodexBridgeWindowsApplication.runDesktopCommand(
              .resolveTaskApproval(
                approvalID: id, taskID: "task-\(id)", decision: "deny",
                oneTimeToolAutoApproval: false
              ), model: model, management: management, auxiliary: auxiliary
            )
          )
        }
      }
      await fulfillment(of: [observed], timeout: 3)
      let requests = await backend.approvalRequests
      XCTAssertEqual(Set(requests.map(\.approvalID)), Set(["a", "b"]))
      XCTAssertTrue(requests.allSatisfy { $0.taskID == "task-\($0.approvalID)" })
    }

    func testWorkspaceSaveKeepsCapturedProjectAndDoesNotReplaceNewSelection() async throws {
      let observed = expectation(description: "Workspace update arrives")
      let backend = CommandTargetBackend(workspaceObserved: observed)
      let client = BridgeServiceClient(transport: CommandTargetTransport(backend: backend))
      let workspace = await MainActor.run {
        WindowsWorkspaceModel(client: client, feedback: WindowsDesktopFeedbackStore())
      }
      await workspace.refresh()
      let task = try await MainActor.run {
        let context = try XCTUnwrap(workspace.editContext)
        let draft = BridgeWorkspaceCommandDraft(
          name: "Build", executable: "D:\\Tools\\build.exe", arguments: "", workingDirectory: "",
          requiresNetwork: false, risk: "normal"
        )
        let pending = Task { await workspace.saveCommand(draft, context: context) }
        workspace.selectedProjectID = "b"
        workspace.detail = CommandTargetBackend.project("b")
        workspace.syncWorkspace()
        return pending
      }
      await fulfillment(of: [observed], timeout: 3)
      await backend.finishWorkspaceUpdate()
      await task.value
      let request = await backend.workspaceRequest
      XCTAssertEqual(request?.projectID, "a")
      XCTAssertEqual(request?.commands.first?.name, "Build")
      await MainActor.run {
        XCTAssertEqual(workspace.selectedProjectID, "b")
        XCTAssertEqual(workspace.detail?.projectID, "b")
        XCTAssertTrue(workspace.commands.isEmpty)
      }
    }
  }

  private final class CommandTargetTransport: ServiceRequestTransport, Sendable {
    let backend: CommandTargetBackend
    var streamHandler: (@Sendable (Data) -> Void)? {
      get { nil }
      set {}
    }

    init(backend: CommandTargetBackend) { self.backend = backend }
    func perform(_ data: Data) async throws -> Data { try await backend.perform(data) }
    func invalidate() {}
  }

  private actor CommandTargetBackend {
    let approvalObserved: XCTestExpectation?
    let workspaceObserved: XCTestExpectation?
    var approvalRequests: [IPCApprovalResolutionRequest] = []
    var workspaceRequest: IPCProjectCommandsUpdateRequest?
    var workspaceContinuation: CheckedContinuation<Void, Never>?

    init(
      approvalObserved: XCTestExpectation? = nil,
      workspaceObserved: XCTestExpectation? = nil
    ) {
      self.approvalObserved = approvalObserved
      self.workspaceObserved = workspaceObserved
    }

    func finishWorkspaceUpdate() {
      workspaceContinuation?.resume()
      workspaceContinuation = nil
    }

    func perform(_ data: Data) async throws -> Data {
      let request = try BridgeServiceIPCCodec.decodeRequest(data)
      switch request.operation {
      case .resolveApproval:
        approvalRequests.append(
          try BridgeServiceIPCCodec.payload(IPCApprovalResolutionRequest.self, from: request))
        approvalObserved?.fulfill()
        return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
      case .listTasks:
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID, payload: IPCTaskListResponse(tasks: []))
      case .listApprovals:
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID, payload: IPCApprovalListResponse(approvals: []))
      case .listDirectApprovals:
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID, payload: IPCDirectApprovalListResponse(approvals: []))
      case .status:
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID,
          payload: IPCServiceStatusResponse(
            status: BridgeStatusSnapshot(
              appVersion: "test", mcpState: "ready", tunnelState: "stopped",
              executionState: "ready", supervisorState: "disabled", pendingApprovalCount: 0
            ), localMCPURL: nil, exposureMode: .readOnly, workbenchProjectID: "a"
          )
        )
      case .listProjects:
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID,
          payload: IPCProjectListResponse(
            projects: ["a", "b"].map {
              MCPProjectSummary(
                projectID: $0, name: $0, capabilities: Self.project($0).capabilities)
            })
        )
      case .getProjectCommands:
        let payload = try BridgeServiceIPCCodec.payload(
          IPCProjectCommandsRequest.self, from: request)
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID, payload: Self.project(payload.projectID))
      case .updateProjectCommands:
        let payload = try BridgeServiceIPCCodec.payload(
          IPCProjectCommandsUpdateRequest.self, from: request)
        workspaceRequest = payload
        await withCheckedContinuation { continuation in
          workspaceContinuation = continuation
          workspaceObserved?.fulfill()
        }
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID, payload: Self.project(payload.projectID))
      default:
        throw BridgeServiceClientError.responseFailed
      }
    }

    nonisolated static func project(_ id: String) -> MCPProjectDetail {
      MCPProjectDetail(
        projectID: id, name: id,
        capabilities: MCPProjectCapabilities(read: "allowed", write: "allowed", network: "denied"),
        directWorkspace: MCPDirectWorkspace(
          fileWritePermission: "allowed", commandMode: "safe", commands: [])
      )
    }
  }
#endif

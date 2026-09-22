import BridgeIPC
import BridgeMCP
import XCTest

@testable import BridgeServiceAppShell

@MainActor
private final class MockRegistration: BridgeServiceRegistrationManaging {
  var status: BridgeServiceRegistrationStatus = .enabled
  func register() throws {}
  func unregister() async throws {}
  func openSystemSettings() {}
}

@MainActor
final class WorkbenchTaskRetryActionTests: XCTestCase {
  func testResumeTaskSubmitsContinuationRequestWithSessionIDAndPrompt() async throws {
    let client = TestBridgeServiceClient()
    await client.configureAgentProviders([
      IPCAgentProviderSummary(
        providerID: "antigravity",
        displayName: "Antigravity",
        adapterRevision: 1,
        supportsSessionContinuation: true,
        supportsSteer: true
      )
    ])
    await client.configureAgentInstallations([
      .init(
        installationID: "agy-inst-1", providerID: "antigravity", displayName: "Antigravity",
        executablePath: "/tmp/agy", adapterRevision: 1, trustProfile: "user_trusted",
        isEnabled: true, availability: "available",
        effectiveCapabilities: ["lifecycle.session_continue"],
        lastProbeError: nil, lastProbedAt: nil, updatedAt: "2026-09-14T00:00:00Z")
    ])
    let registration = MockRegistration()
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()

    let task = MCPServiceTaskSnapshot(
      taskID: "task-fail-1",
      projectID: "proj-1",
      prompt: "修复所有编译错误",
      status: "failed",
      providerID: "antigravity",
      installationID: "agy-inst-1",
      executionModel: "gemini-2.5",
      executionEffort: "high",
      providerSessionID: "sess-abc-123",
      permissionMode: "workspace-write",
      networkAccess: true,
      supervisorStatus: "none",
      localApprovalRequired: false,
      failureCode: "timeout",
      updatedAt: "2026-09-03T10:00:00Z"
    )

    XCTAssertTrue(task.isFailedOrInterrupted)
    XCTAssertTrue(task.canResumeSession)
    XCTAssertEqual(task.effectiveSessionID, "sess-abc-123")

    model.resumeTask(task, prompt: "继续处理剩下的文件")

    try await Task.sleep(for: .milliseconds(50))

    let tasks = await client.submittedAgentTasksValue()
    XCTAssertEqual(tasks.count, 1)
    let submitted = try XCTUnwrap(tasks.first)
    XCTAssertEqual(submitted.projectID, "proj-1")
    XCTAssertEqual(submitted.providerID, "antigravity")
    XCTAssertEqual(submitted.installationID, "agy-inst-1")
    XCTAssertEqual(submitted.model, "gemini-2.5")
    XCTAssertEqual(submitted.effort, "high")
    XCTAssertEqual(submitted.permissionMode, "workspace-write")
    XCTAssertEqual(submitted.networkAccess, true)
    XCTAssertEqual(submitted.threadID, "sess-abc-123")
    XCTAssertEqual(submitted.prompt, "继续处理剩下的文件")
    XCTAssertEqual(submitted.modelOverride, true)
    XCTAssertEqual(submitted.permissionModeOverride, true)
  }

  func testResumeTaskUsesDefaultPromptWhenInputIsEmpty() async throws {
    let client = TestBridgeServiceClient()
    let registration = MockRegistration()
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()

    let task = MCPServiceTaskSnapshot(
      taskID: "task-fail-2",
      projectID: "proj-1",
      prompt: "整理测试用例",
      status: "interrupted",
      providerID: "codex",
      threadID: "th-codex-999",
      turnID: "turn-1",
      permissionMode: "read-only",
      supervisorStatus: "none",
      localApprovalRequired: false,
      updatedAt: "2026-09-03T10:00:00Z"
    )

    XCTAssertTrue(task.isFailedOrInterrupted)
    XCTAssertTrue(task.canResumeSession)
    XCTAssertEqual(task.effectiveSessionID, "th-codex-999")

    model.resumeTask(task, prompt: "   ")

    try await Task.sleep(for: .milliseconds(50))

    let tasks = await client.submittedAgentTasksValue()
    XCTAssertEqual(tasks.count, 1)
    let submitted = try XCTUnwrap(tasks.first)
    XCTAssertEqual(submitted.threadID, "th-codex-999")
    XCTAssertEqual(submitted.prompt, "继续执行未完成的任务")
  }

  func testResumeTaskDoesNotTreatProviderDefaultAsModelOverride() async throws {
    let client = TestBridgeServiceClient()
    let registration = MockRegistration()
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()

    let task = MCPServiceTaskSnapshot(
      taskID: "task-default-model",
      projectID: "proj-1",
      status: "completed",
      providerID: "codex",
      executionModel: "provider-default",
      executionEffort: "provider-default",
      threadID: "thread-default-model",
      permissionMode: "workspace-write",
      supervisorStatus: "none",
      localApprovalRequired: false,
      updatedAt: "2026-09-03T10:00:00Z"
    )

    model.resumeTask(task, prompt: "继续执行")

    try await Task.sleep(for: .milliseconds(50))

    let submissions = await client.submittedAgentTasksValue()
    let submitted = try XCTUnwrap(submissions.first)
    XCTAssertEqual(submitted.threadID, "thread-default-model")
    XCTAssertEqual(submitted.model, "provider-default")
    XCTAssertNil(submitted.effort)
    XCTAssertEqual(submitted.modelOverride, false)
  }

  func testResumeTaskDropsTheEffortSentinelWhileKeepingAModelOverride() async throws {
    let client = TestBridgeServiceClient()
    let registration = MockRegistration()
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()

    let task = MCPServiceTaskSnapshot(
      taskID: "task-real-model",
      projectID: "proj-1",
      status: "completed",
      providerID: "codex",
      executionModel: "gpt-5-codex",
      executionEffort: "provider-default",
      threadID: "thread-real-model",
      permissionMode: "workspace-write",
      supervisorStatus: "none",
      localApprovalRequired: false,
      updatedAt: "2026-09-03T10:00:00Z"
    )

    model.resumeTask(task, prompt: "继续执行")

    try await Task.sleep(for: .milliseconds(50))

    let submissions = await client.submittedAgentTasksValue()
    let submitted = try XCTUnwrap(submissions.first)
    // The service rejects an explicit effort that the selected model does not
    // list, so the sentinel has to fall back to the configured default.
    XCTAssertEqual(submitted.model, "gpt-5-codex")
    XCTAssertEqual(submitted.modelOverride, true)
    XCTAssertNil(submitted.effort)
  }

  func testRestartTaskSubmitsFreshRequestWithOriginalPromptAndNoThreadID() async throws {
    let client = TestBridgeServiceClient()
    let registration = MockRegistration()
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()

    let task = MCPServiceTaskSnapshot(
      taskID: "task-fail-3",
      projectID: "proj-2",
      prompt: "从零重构认证模块",
      status: "failed",
      providerID: "deepseek-harness",
      installationID: "dsh-1",
      executionModel: "deepseek-chat",
      executionEffort: "low",
      providerSessionID: "sess-dsh-old",
      permissionMode: "workspace-write",
      networkAccess: false,
      supervisorStatus: "none",
      localApprovalRequired: false,
      failureCode: "process_terminated",
      updatedAt: "2026-09-03T10:00:00Z"
    )

    XCTAssertTrue(task.canRestart)

    model.restartTask(task)

    try await Task.sleep(for: .milliseconds(50))

    let tasks = await client.submittedAgentTasksValue()
    XCTAssertEqual(tasks.count, 1)
    let submitted = try XCTUnwrap(tasks.first)
    XCTAssertEqual(submitted.projectID, "proj-2")
    XCTAssertEqual(submitted.providerID, "deepseek-harness")
    XCTAssertEqual(submitted.prompt, "从零重构认证模块")
    XCTAssertNil(submitted.threadID)
    XCTAssertEqual(submitted.model, "deepseek-chat")
    XCTAssertEqual(submitted.effort, "low")
  }

  func testSteerableHelpersForRunningTasks() {
    let codexRunning = MCPServiceTaskSnapshot(
      taskID: "task-run-1",
      projectID: "proj-1",
      status: "running",
      providerID: "codex",
      threadID: "th-1",
      turnID: "turn-42",
      supervisorStatus: "none",
      localApprovalRequired: false,
      updatedAt: "2026-09-03T10:00:00Z"
    )
    XCTAssertTrue(codexRunning.canSteer)
    XCTAssertEqual(codexRunning.expectedControlID, "turn-42")
    XCTAssertFalse(codexRunning.isFailedOrInterrupted)

    let agyRunning = MCPServiceTaskSnapshot(
      taskID: "task-run-2",
      projectID: "proj-1",
      status: "running",
      providerID: "antigravity",
      providerSessionID: "sess-1",
      providerRunID: "run-99",
      supervisorStatus: "none",
      localApprovalRequired: false,
      updatedAt: "2026-09-03T10:00:00Z"
    )
    XCTAssertTrue(agyRunning.canSteer)
    XCTAssertEqual(agyRunning.expectedControlID, "run-99")
    XCTAssertFalse(agyRunning.isFailedOrInterrupted)
  }
}

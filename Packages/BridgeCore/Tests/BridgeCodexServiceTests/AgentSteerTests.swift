import BridgeAgentCore
import BridgeCodexService
import BridgeDomain
import BridgeServiceCore
import XCTest

final class AgentSteerTests: XCTestCase {
  func testCoordinatorRoutesAgentSteerAndPersistsUserMessage() async throws {
    let fixture = try await makeExecutionFixture(self)
    let taskID = TaskID(rawValue: "tsk-agent-steer")
    let submitted = try await fixture.tasks.submit(
      ServiceTaskRequest(
        projectID: fixture.project.id,
        source: .chatGPT,
        clientRequestID: "request-agent-steer",
        prompt: "Inspect the repository.",
        providerID: "opencode",
        installationID: "ainst-agent-steer",
        selectionMode: .explicit,
        executionModel: serviceDefaultProviderExecutionModel,
        executionEffort: serviceDefaultProviderExecutionEffort,
        permissionMode: .readOnly
      ),
      taskID: taskID
    )
    _ = try await fixture.tasks.begin(taskID: submitted.task.id)
    let runner = SteerableAgentRunner()
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: makeExecutionManager(script: "exit 0"),
      agentRunner: runner
    )
    addTeardownBlock { await coordinator.shutdown() }

    _ = try await coordinator.start(taskID: taskID)
    let running = try await waitForTask(fixture, taskID: taskID) {
      $0.state.status == .running
    }
    let runID = try XCTUnwrap(running.state.providerRunID)
    let queuedText = "Focus on the failing test."
    let immediateText = "Stop the current attempt and summarize."
    try await coordinator.steer(taskID: taskID, expectedTurnID: runID, text: queuedText)
    try await coordinator.steer(
      taskID: taskID,
      expectedTurnID: runID,
      text: immediateText,
      interruptCurrentPrompt: true
    )

    let steerInputs = await runner.steerInputs
    let immediateSteerInputs = await runner.immediateSteerInputs
    XCTAssertEqual(steerInputs, [queuedText])
    XCTAssertEqual(immediateSteerInputs, [immediateText])

    func persistedUserMessageCount(_ content: String) async throws -> Int {
      try await coordinator.conversationPage(taskID: taskID)
        .filter { $0.role == .user && $0.content == content }
        .count
    }

    // A steer is persisted once from the provider's dispatch event. Equal text
    // from two accepted inputs remains two distinct conversation messages.
    let immediatePersisted = try await waitForUserMessageCount(
      immediateText, count: 1, coordinator: coordinator, taskID: taskID)
    XCTAssertEqual(immediatePersisted, 1)
    let queuedBeforeDispatch = try await persistedUserMessageCount(queuedText)
    XCTAssertEqual(queuedBeforeDispatch, 0)

    try await coordinator.steer(
      taskID: taskID,
      expectedTurnID: runID,
      text: immediateText,
      interruptCurrentPrompt: true
    )
    let repeatedImmediatePersisted = try await waitForUserMessageCount(
      immediateText, count: 2, coordinator: coordinator, taskID: taskID)
    XCTAssertEqual(repeatedImmediatePersisted, 2)

    try await runner.dispatchSteer(queuedText)
    let queuedPersisted = try await waitForUserMessageCount(
      queuedText, count: 1, coordinator: coordinator, taskID: taskID)
    XCTAssertEqual(queuedPersisted, 1)

    let contents = try await coordinator.conversationPage(taskID: taskID)
      .filter { $0.role == .user }
      .map(\.content)
    XCTAssertEqual(
      Array(contents.suffix(3)), [immediateText, immediateText, queuedText])
  }

  private func waitForUserMessageCount(
    _ content: String,
    count: Int,
    coordinator: ServiceExecutionCoordinator,
    taskID: TaskID
  ) async throws -> Int {
    for _ in 0..<100 {
      let current = try await coordinator.conversationPage(taskID: taskID)
        .filter { $0.role == .user && $0.content == content }
        .count
      if current >= count { return current }
      try await Task.sleep(for: .milliseconds(10))
    }
    return try await coordinator.conversationPage(taskID: taskID)
      .filter { $0.role == .user && $0.content == content }
      .count
  }
}

private actor SteerableAgentRunner: AgentTaskRunning {
  private var continuation: AsyncThrowingStream<AgentEventEnvelope, any Error>.Continuation?
  private var brief: AgentTaskBrief?
  private var providerSequence: Int64 = 0
  private(set) var steerInputs: [String] = []
  private(set) var immediateSteerInputs: [String] = []

  func start(_ brief: AgentTaskBrief) async throws -> AgentTaskRunHandle {
    let pair = AsyncThrowingStream.makeStream(
      of: AgentEventEnvelope.self,
      throwing: (any Error).self
    )
    continuation = pair.continuation
    self.brief = brief
    return AgentTaskRunHandle(
      sessionID: "session-\(brief.taskID.rawValue)",
      runID: "run-\(brief.taskID.rawValue)",
      events: pair.stream,
      interrupt: {},
      steer: { [weak self] text in
        await self?.recordSteer(text)
      },
      interruptAndSteer: { [weak self] text in
        await self?.recordImmediateSteer(text)
      },
      shutdown: { [weak self] in
        await self?.finish()
      }
    )
  }

  /// Mirrors what a real provider does once a queued steer is handed to the agent.
  func dispatchSteer(_ text: String) throws {
    guard let brief, let continuation else {
      throw AgentRuntimeError.processUnavailable
    }
    providerSequence += 1
    try continuation.yield(
      AgentEventEnvelope(
        taskID: brief.taskID,
        providerID: brief.providerID,
        providerSessionID: "session-\(brief.taskID.rawValue)",
        providerRunID: "run-\(brief.taskID.rawValue)",
        providerSequence: providerSequence,
        event: .steerDispatched(text)
      )
    )
  }

  func recordSteer(_ text: String) {
    steerInputs.append(text)
  }

  func recordImmediateSteer(_ text: String) {
    immediateSteerInputs.append(text)
    try? dispatchSteer(text)
  }

  func finish() {
    continuation?.finish()
    continuation = nil
  }
}

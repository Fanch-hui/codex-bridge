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

    func persistedUserMessage(_ content: String) async throws -> Bool {
      try await coordinator.conversationPage(taskID: taskID)
        .contains { $0.role == .user && $0.content == content }
    }

    // An immediate steer reaches the agent at once, so its instruction is recorded
    // immediately. A queued one only belongs to the turn it eventually starts.
    let immediatePersisted = try await persistedUserMessage(immediateText)
    XCTAssertTrue(immediatePersisted)
    let queuedPersisted = try await persistedUserMessage(queuedText)
    XCTAssertFalse(queuedPersisted)

    try await runner.dispatchSteer(queuedText)
    var dispatched = false
    for _ in 0..<100 {
      dispatched = try await persistedUserMessage(queuedText)
      if dispatched { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(dispatched)

    let contents = try await coordinator.conversationPage(taskID: taskID)
      .filter { $0.role == .user }
      .map(\.content)
    XCTAssertEqual(Array(contents.suffix(2)), [immediateText, queuedText])
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
  }

  func finish() {
    continuation?.finish()
    continuation = nil
  }
}
